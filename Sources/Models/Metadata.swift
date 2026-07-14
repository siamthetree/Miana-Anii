// ==========================================================
//  BUG 7  -  SIXTY IDENTICAL TMDB CALLS  (file 1 of 3)
//
//  File:  Sources/Models/Metadata.swift
//  Replace the entire file. Supersedes FIX-4a.
//
//  Adds TMDBCache in front of search and detail.
//
//  It caches the in-flight Task, not the finished result. That is the
//  whole trick. Caching results would not help here: sixty episodes
//  refreshing at once all start before any of them finishes, so they
//  would all miss the cache and all hit the network. Handing every
//  latecomer the same Task means one call and fifty-nine awaits.
//
//  Per-episode data is not cached. Those answers really are different.
// ==========================================================

import Foundation

// MARK: - Stored model

struct CastMember: Codable, Hashable {
    let name: String
    let profileURL: URL?
}

struct MediaMetadata: Codable, Hashable {
    var tmdbID: Int
    var title: String
    var overview: String
    var posterURL: URL?
    var backdropURL: URL?
    var releaseYear: String
    var isTVShow: Bool
    var season: Int?
    var episode: Int?
    var rating: Double?
    var genres: [String] = []
    var cast: [CastMember] = []

    // Season and episode detail. Optional, so older library.json files
    // still decode. They stay nil until you hit Refresh Metadata.
    var episodeTitle: String? = nil
    var episodeOverview: String? = nil
    var stillURL: URL? = nil
    var airDate: String? = nil
    var seasonName: String? = nil
    var seasonOverview: String? = nil
    var seasonPosterURL: URL? = nil
}

// MARK: - TMDB wire format

struct TMDBResponse: Codable { let results: [TMDBResult] }

struct TMDBResult: Codable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let poster_path: String?
    let backdrop_path: String?
    let release_date: String?
    let first_air_date: String?

    var displayName: String { title ?? name ?? "" }
    var year: Int? { Int((release_date ?? first_air_date ?? "").prefix(4)) }
}

struct TMDBGenre: Codable { let name: String }
struct TMDBCast: Codable { let name: String; let profile_path: String? }
struct TMDBCredits: Codable { let cast: [TMDBCast]? }
struct TMDBSeasonSummary: Codable {
    let season_number: Int
    let name: String?
    let overview: String?
    let poster_path: String?
}
struct TMDBDetailResponse: Codable {
    let vote_average: Double?
    let genres: [TMDBGenre]?
    let credits: TMDBCredits?
    let seasons: [TMDBSeasonSummary]?
}
struct TMDBEpisodeResponse: Codable {
    let name: String?
    let overview: String?
    let still_path: String?
    let air_date: String?
}

// MARK: - Cache

/// Sixty episodes of one show ask TMDB the same two questions sixty times: what
/// is this show, and what are its details. The answers are identical every time.
///
/// This caches both, and also caches the in-flight Task rather than the result,
/// so sixty episodes refreshing at once produce one network call and fifty-nine
/// awaits on it. Caching only the finished result would not help: they all start
/// before any of them finishes.
///
/// Per-episode data is deliberately not cached. Those answers really are different.
actor TMDBCache {
    static let shared = TMDBCache()

    private var searches: [String: Task<TMDBResult?, Never>] = [:]
    private var details: [String: Task<TMDBDetailResponse?, Never>] = [:]

    func search(type: String, query: String, year: Int?, fetch: @escaping @Sendable () async -> TMDBResult?) async -> TMDBResult? {
        let key = "\(type)|\(query.lowercased())|\(year.map(String.init) ?? "-")"
        if let existing = searches[key] { return await existing.value }
        let task = Task { await fetch() }
        searches[key] = task
        return await task.value
    }

    func detail(type: String, id: Int, fetch: @escaping @Sendable () async -> TMDBDetailResponse?) async -> TMDBDetailResponse? {
        let key = "\(type)|\(id)"
        if let existing = details[key] { return await existing.value }
        let task = Task { await fetch() }
        details[key] = task
        return await task.value
    }

    /// Called at the start of a refresh, so a title that failed last time, or one
    /// whose TMDB entry has since been corrected, is asked about again.
    func clear() {
        searches.removeAll()
        details.removeAll()
    }
}

// MARK: - Service

final class MetadataService {

    static var apiKey: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["TMDBAPIKey"] as? String else { return "" }
        return key
    }

    static let baseURL = "https://api.themoviedb.org/3"
    static let posterBaseURL = "https://image.tmdb.org/t/p/w500"
    static let backdropBaseURL = "https://image.tmdb.org/t/p/w780"
    static let stillBaseURL = "https://image.tmdb.org/t/p/w300"
    static let profileBaseURL = "https://image.tmdb.org/t/p/w185"

    // MARK: Entry point

    static func fetchMetadata(for filename: String, cleanTitle: String) async -> MediaMetadata? {
        guard !apiKey.isEmpty else { return nil }

        let base = (filename as NSString).deletingPathExtension
        let (parsedSeason, parsedEpisode) = parseEpisode(from: base)
        let hasSeasonKeyword = base.range(of: "(?i)season\\s*\\d{1,2}", options: .regularExpression) != nil
        let looksLikeTV = parsedSeason != nil || hasSeasonKeyword

        var (query, year) = searchQuery(from: cleanTitle)
        if year == nil, let detected = detectYear(in: base) { year = detected.year }
        if query.isEmpty { query = searchQuery(from: base).query }
        if query.isEmpty { query = cleanTitle }
        guard !query.isEmpty else { return nil }

        // Guess the right endpoint, then fall back through the alternatives.
        var type = looksLikeTV ? "tv" : "movie"
        var hit = await search(type: type, query: query, year: year)
        if hit == nil, year != nil { hit = await search(type: type, query: query, year: nil) }
        if hit == nil {
            type = looksLikeTV ? "movie" : "tv"
            hit = await search(type: type, query: query, year: nil)
        }
        guard let result = hit else { return nil }

        let isTV = (type == "tv")
        let season = isTV ? (parsedSeason ?? (hasSeasonKeyword ? 1 : nil)) : nil
        let episode = isTV ? parsedEpisode : nil

        var metadata = MediaMetadata(
            tmdbID: result.id,
            title: result.displayName.isEmpty ? cleanTitle : result.displayName,
            overview: result.overview ?? "",
            posterURL: result.poster_path.flatMap { URL(string: posterBaseURL + $0) },
            backdropURL: result.backdrop_path.flatMap { URL(string: backdropBaseURL + $0) },
            releaseYear: String((result.release_date ?? result.first_air_date ?? "").prefix(4)),
            isTVShow: isTV,
            season: season,
            episode: episode
        )

        let detail = await fetchDetail(type: type, id: result.id)
        metadata.rating = detail?.vote_average
        metadata.genres = detail?.genres?.map(\.name) ?? []
        metadata.cast = detail?.credits?.cast?.prefix(12).map {
            CastMember(name: $0.name, profileURL: $0.profile_path.flatMap { URL(string: profileBaseURL + $0) })
        } ?? []

        if isTV, let season {
            if let summary = detail?.seasons?.first(where: { $0.season_number == season }) {
                metadata.seasonName = summary.name
                metadata.seasonOverview = summary.overview
                metadata.seasonPosterURL = summary.poster_path.flatMap { URL(string: posterBaseURL + $0) }
            }
            if let episode, let ep = await fetchEpisode(showID: result.id, season: season, episode: episode), ep.name != nil {
                metadata.episodeTitle = ep.name
                metadata.episodeOverview = ep.overview
                metadata.stillURL = ep.still_path.flatMap { URL(string: stillBaseURL + $0) }
                metadata.airDate = ep.air_date
            }
        }

        return metadata
    }

    // MARK: Requests

    private static func search(type: String, query: String, year: Int?) async -> TMDBResult? {
        await TMDBCache.shared.search(type: type, query: query, year: year) {
            await performSearch(type: type, query: query, year: year)
        }
    }

    private static func performSearch(type: String, query: String, year: Int?) async -> TMDBResult? {
        guard var components = URLComponents(string: "\(baseURL)/search/\(type)") else { return nil }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US")
        ]
        if let year {
            let key = (type == "tv") ? "first_air_date_year" : "primary_release_year"
            items.append(URLQueryItem(name: key, value: String(year)))
        }
        components.queryItems = items

        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(TMDBResponse.self, from: data),
              !response.results.isEmpty else { return nil }

        if let year, let exact = response.results.first(where: { $0.year == year }) { return exact }
        let target = query.lowercased()
        if let exact = response.results.first(where: { $0.displayName.lowercased() == target }) { return exact }
        return response.results.first
    }

    private static func fetchDetail(type: String, id: Int) async -> TMDBDetailResponse? {
        await TMDBCache.shared.detail(type: type, id: id) {
            await performDetail(type: type, id: id)
        }
    }

    private static func performDetail(type: String, id: Int) async -> TMDBDetailResponse? {
        guard let url = URL(string: "\(baseURL)/\(type)/\(id)?api_key=\(apiKey)&language=en-US&append_to_response=credits"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TMDBDetailResponse.self, from: data)
    }

    private static func fetchEpisode(showID: Int, season: Int, episode: Int) async -> TMDBEpisodeResponse? {
        guard let url = URL(string: "\(baseURL)/tv/\(showID)/season/\(season)/episode/\(episode)?api_key=\(apiKey)&language=en-US"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TMDBEpisodeResponse.self, from: data)
    }

    // MARK: Filename parsing

    /// Recognises S01E02, s1e2, 1x03 and "Season 1 ... Episode 3".
    static func parseEpisode(from name: String) -> (Int?, Int?) {
        if let m = captures("(?i)s(\\d{1,2})\\s?e(\\d{1,2})", in: name) { return (m[0], m[1]) }
        if let m = captures("(?i)(?:^|[^a-z0-9])(\\d{1,2})x(\\d{2})(?:[^a-z0-9]|$)", in: name) { return (m[0], m[1]) }
        if let m = captures("(?i)season\\s*(\\d{1,2}).*?episode\\s*(\\d{1,2})", in: name) { return (m[0], m[1]) }
        return (nil, nil)
    }

    /// Strips episode tokens, brackets and the release year from a title,
    /// and hands the year back separately so it can be sent as its own parameter.
    static func searchQuery(from title: String) -> (query: String, year: Int?) {
        var s = title
        s = s.replacingOccurrences(of: "(?i)\\bs\\d{1,2}\\s?e\\d{1,2}\\b.*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)(?:^|[^a-z0-9])\\d{1,2}x\\d{2}(?:[^a-z0-9]|$).*", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\bseason\\s*\\d{1,2}\\b.*", with: "", options: .regularExpression)

        var year: Int?
        if let detected = detectYear(in: s) {
            year = detected.year
            s.removeSubrange(detected.range)
        }

        s = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\([^\\)]*\\)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[._]", with: " ")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -_.[](){}"))
        return (s, year)
    }

    /// Last plausible four digit year. "Blade Runner 2049" keeps 2049 in the
    /// title because 2049 is not a plausible release year.
    static func detectYear(in text: String) -> (year: Int, range: Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: "\\b(?:19|20)\\d{2}\\b") else { return nil }
        let limit = Calendar.current.component(.year, from: Date()) + 2
        var best: (Int, Range<String.Index>)?
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let range = Range(match.range, in: text), let value = Int(text[range]) else { return }
            if value >= 1900 && value <= limit { best = (value, range) }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    private static func captures(_ pattern: String, in text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return nil }
        var values: [Int] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text), let value = Int(text[range]) else { return nil }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }
}
