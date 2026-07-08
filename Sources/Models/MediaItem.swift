

import Foundation

enum MediaKinds {
    static let video: Set<String> = ["mp4", "m4v", "mov", "3gp", "mkv", "avi", "webm", "ts", "m2ts", "mts", "flv", "wmv", "mpg", "mpeg", "vob", "ogv"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "caf", "aif", "aiff", "flac", "ogg", "opus", "wma"]
    static let subtitles: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]
    static let native: Set<String> = ["mp4", "m4v", "mov", "3gp", "mp3", "m4a", "aac", "wav", "caf", "aif", "aiff", "flac"]
    static var media: Set<String> { video.union(audio) }
}

struct MediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var dateAdded: Date = Date()
    var duration: Double = 0
    var lastPosition: Double = 0
    var lastPlayed: Date? = nil
    var metadata: MediaMetadata? = nil
    var folderID: UUID? = nil
    var relativePath: String? = nil

    var progress: Double { guard duration > 0 else { return 0 }; return min(max(lastPosition / duration, 0), 1) }
    var isWatched: Bool { duration > 0 && progress >= 0.95 }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    var isAudio: Bool { MediaKinds.audio.contains(fileExtension) }
    var isExternal: Bool { folderID != nil }
    var isEngineSupported: Bool { MediaKinds.native.contains(fileExtension) }
}

// MARK: - Episode helpers

extension MediaItem {

    static let qualityMarkers = ["1080p", "720p", "2160p", "480p", "4k", "x264", "x265", "h264", "h265",
                                 "hevc", "web-dl", "webdl", "webrip", "bluray", "brrip", "bdrip", "hdrip",
                                 "hdtv", "dvdrip", "remux", "10bit", "yify", "rarbg", "aac", "ddp", "dts"]

    var isEpisode: Bool { metadata?.isTVShow == true }

    /// Stable identity for the show this file belongs to, or nil for a movie.
    var seriesKey: String? {
        guard let m = metadata, m.isTVShow else { return nil }
        if m.tmdbID > 0 { return "tmdb-\(m.tmdbID)" }
        let name = m.title.isEmpty ? title : m.title
        return "name-" + name.lowercased()
    }

    var seasonNumber: Int { metadata?.season ?? 1 }
    var episodeNumber: Int { metadata?.episode ?? 0 }

    var episodeCode: String {
        episodeNumber > 0 ? String(format: "S%02dE%02d", seasonNumber, episodeNumber)
                          : "Season \(seasonNumber)"
    }

    /// TMDB still for this exact episode, when we have one.
    var stillURL: URL? { metadata?.stillURL }

    var episodeOverview: String? {
        guard let text = metadata?.episodeOverview, !text.isEmpty else { return nil }
        return text
    }

    /// "20 January 2008"
    var formattedAirDate: String? {
        guard let raw = metadata?.airDate, !raw.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: raw) else { return raw }
        let printer = DateFormatter()
        printer.dateStyle = .long
        printer.timeStyle = .none
        return printer.string(from: date)
    }

    /// Everything between the S01E02 token and the first quality marker.
    var episodeNameFromFile: String? {
        let base = (fileName as NSString).deletingPathExtension
        guard let range = base.range(of: "(?i)s\\d{1,2}\\s?e\\d{1,2}", options: .regularExpression)
                ?? base.range(of: "(?i)(?<![a-z0-9])\\d{1,2}x\\d{2}", options: .regularExpression) else { return nil }

        var tail = String(base[range.upperBound...]).replacingOccurrences(of: "_", with: " ")
        if !tail.contains(" ") { tail = tail.replacingOccurrences(of: ".", with: " ") }

        let lower = tail.lowercased()
        var cut = tail.count
        for marker in MediaItem.qualityMarkers {
            if let r = lower.range(of: marker) {
                cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound))
            }
        }
        if cut < tail.count { tail = String(tail.prefix(cut)) }
        tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: " -._[]()"))
        return tail.isEmpty ? nil : tail
    }

    /// TMDB episode title wins, then the filename, then a plain number.
    var displayEpisodeTitle: String {
        if let tmdb = metadata?.episodeTitle, !tmdb.isEmpty { return tmdb }
        if let fromFile = episodeNameFromFile { return fromFile }
        return episodeNumber > 0 ? "Episode \(episodeNumber)" : title
    }
}

// MARK: - Grouped library model

struct Season: Identifiable, Hashable {
    let number: Int
    let name: String?
    let overview: String?
    let posterURL: URL?
    let episodes: [MediaItem]

    var id: Int { number }
    var displayName: String {
        if let name, !name.isEmpty, name.lowercased() != "season \(number)" { return name }
        return number == 0 ? "Specials" : "Season \(number)"
    }
    var unwatchedCount: Int { episodes.filter { !$0.isWatched }.count }
    var episodeCountText: String { episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes" }
    var nextUp: MediaItem? {
        episodes.first(where: { $0.progress > 0.01 && !$0.isWatched }) ?? episodes.first(where: { !$0.isWatched })
    }
}

struct Series: Identifiable {
    let id: String
    let title: String
    let posterURL: URL?
    let backdropURL: URL?
    let overview: String
    let releaseYear: String
    let rating: Double?
    let genres: [String]
    let cast: [CastMember]
    let episodes: [MediaItem]

    var seasons: [Season] {
        Dictionary(grouping: episodes, by: { $0.seasonNumber })
            .map { number, eps in
                let sorted = eps.sorted { lhs, rhs in
                    if lhs.episodeNumber != rhs.episodeNumber { return lhs.episodeNumber < rhs.episodeNumber }
                    return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
                }
                return Season(
                    number: number,
                    name: eps.compactMap { $0.metadata?.seasonName }.first,
                    overview: eps.compactMap { $0.metadata?.seasonOverview }.first(where: { !$0.isEmpty }),
                    posterURL: eps.compactMap { $0.metadata?.seasonPosterURL }.first ?? posterURL,
                    episodes: sorted
                )
            }
            .sorted { $0.number < $1.number }
    }

    var episodeCount: Int { episodes.count }
    var unwatchedCount: Int { episodes.filter { !$0.isWatched }.count }
    var dateAdded: Date { episodes.map(\.dateAdded).max() ?? .distantPast }
    var lastPlayed: Date? { episodes.compactMap(\.lastPlayed).max() }

    var subtitle: String {
        let count = seasons.count
        let seasonText = count == 1 ? "1 season" : "\(count) seasons"
        let episodeText = episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes"
        return "\(seasonText) • \(episodeText)"
    }

    /// Half-watched episode first, then the earliest unwatched one.
    var nextUp: MediaItem? {
        let ordered = seasons.flatMap(\.episodes)
        if let inProgress = ordered
            .filter({ $0.progress > 0.01 && !$0.isWatched })
            .max(by: { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }) {
            return inProgress
        }
        return ordered.first(where: { !$0.isWatched }) ?? ordered.first
    }
}

enum LibraryEntry: Identifiable {
    case movie(MediaItem)
    case series(Series)

    var id: String {
        switch self {
        case .movie(let item): return "movie-" + item.id.uuidString
        case .series(let show): return show.id
        }
    }

    var sortTitle: String {
        switch self {
        case .movie(let item): return item.metadata?.title ?? item.title
        case .series(let show): return show.title
        }
    }

    var dateAdded: Date {
        switch self {
        case .movie(let item): return item.dateAdded
        case .series(let show): return show.dateAdded
        }
    }

    var lastPlayed: Date? {
        switch self {
        case .movie(let item): return item.lastPlayed
        case .series(let show): return show.lastPlayed
        }
    }
}

extension Array where Element == MediaItem {

    /// Collapses every episode of a show into a single Series entry.
    /// Movies, and any file TMDB could not identify, pass through untouched.
    func groupedIntoEntries() -> [LibraryEntry] {
        var buckets: [String: [MediaItem]] = [:]
        var order: [String] = []
        var entries: [LibraryEntry] = []

        for item in self {
            guard let key = item.seriesKey else {
                entries.append(.movie(item))
                continue
            }
            if buckets[key] == nil { buckets[key] = []; order.append(key) }
            buckets[key]?.append(item)
        }

        for key in order {
            guard let eps = buckets[key], let first = eps.first else { continue }
            let meta = eps.compactMap(\.metadata).first
            entries.append(.series(Series(
                id: key,
                title: meta?.title ?? first.title,
                posterURL: eps.compactMap { $0.metadata?.posterURL }.first,
                backdropURL: eps.compactMap { $0.metadata?.backdropURL }.first,
                overview: meta?.overview ?? "",
                releaseYear: meta?.releaseYear ?? "",
                rating: eps.compactMap { $0.metadata?.rating }.first,
                genres: eps.compactMap { $0.metadata?.genres }.first(where: { !$0.isEmpty }) ?? [],
                cast: eps.compactMap { $0.metadata?.cast }.first(where: { !$0.isEmpty }) ?? [],
                episodes: eps
            )))
        }

        return entries
    }

    func series(withID id: String) -> Series? {
        for entry in groupedIntoEntries() {
            if case .series(let show) = entry, show.id == id { return show }
        }
        return nil
    }
}
