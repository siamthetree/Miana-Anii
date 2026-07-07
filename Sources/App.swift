import Foundation
import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit
import UniformTypeIdentifiers
import MobileVLCKit

// ============================================================
// MinaAniiApp.swift
// ============================================================

@main
struct MinaAniiApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(.purple)
                .task { await TraktService.shared.refreshIfNeeded() }
                .onOpenURL { url in
                    if url.scheme == "minaanii" {
                        Task { await TraktService.shared.handleAuthRedirect(url: url) }
                    } else {
                        Task { await store.importFile(url); store.save() }
                    }
                }
        }
    }
}

// ============================================================
// Trakt & Keychain Service
// ============================================================

enum Keychain {
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

struct TraktTokenResponse: Codable { let access_token: String; let refresh_token: String?; let expires_in: Int?; let created_at: Int? }

@MainActor
final class TraktService: ObservableObject {
    static let shared = TraktService()
    private enum Key { static let access = "trakt.accessToken"; static let refresh = "trakt.refreshToken"; static let expiry = "trakt.expiresAt" }
    private let redirectURI = "minaanii://oauth/trakt"

    private var clientID: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"), let dict = NSDictionary(contentsOfFile: path) as? [String: Any], let key = dict["TraktClientID"] as? String else { return "" }
        return key
    }
    private var clientSecret: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"), let dict = NSDictionary(contentsOfFile: path) as? [String: Any], let key = dict["TraktClientSecret"] as? String else { return "" }
        return key
    }

    @Published private(set) var accessToken: String
    private var refreshToken: String?; private var expiresAt: Date?
    @Published var isAuthenticating = false
    var isAuthenticated: Bool { !accessToken.isEmpty }
    
    var authorizationURL: URL? {
        guard !clientID.isEmpty else { return nil }
        return URL(string: "https://trakt.tv/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=\(redirectURI)")
    }

    private init() {
        accessToken = Keychain.get(Key.access) ?? ""; refreshToken = Keychain.get(Key.refresh)
        if let raw = Keychain.get(Key.expiry), let ts = Double(raw) { expiresAt = Date(timeIntervalSince1970: ts) }
    }

    private func persistTokens(_ token: TraktTokenResponse) {
        accessToken = token.access_token; Keychain.set(token.access_token, for: Key.access)
        if let refresh = token.refresh_token { refreshToken = refresh; Keychain.set(refresh, for: Key.refresh) }
        if let expiresIn = token.expires_in {
            let base = token.created_at.map(Double.init) ?? Date().timeIntervalSince1970
            let expiry = base + Double(expiresIn); expiresAt = Date(timeIntervalSince1970: expiry); Keychain.set(String(expiry), for: Key.expiry)
        }
    }

    func handleAuthRedirect(url: URL) async {
        guard url.scheme == "minaanii", url.host == "oauth", url.path == "/trakt" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { isAuthenticating = false; return }
        
        isAuthenticating = true
        guard let tokenURL = URL(string: "https://api.trakt.tv/oauth/token") else { return }
        var request = URLRequest(url: tokenURL); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["code": code, "client_id": clientID, "client_secret": clientSecret, "redirect_uri": redirectURI, "grant_type": "authorization_code"]
        request.httpBody = try? JSONEncoder().encode(body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let tokenData = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) { persistTokens(tokenData) }
        } catch { print("Trakt Error: \(error)") }
        isAuthenticating = false
    }

    func refreshIfNeeded() async {
        guard !accessToken.isEmpty, let refreshToken, let expiresAt else { return }
        guard Date() > expiresAt.addingTimeInterval(-7 * 24 * 3600) else { return }
        guard let url = URL(string: "https://api.trakt.tv/oauth/token") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["refresh_token": refreshToken, "client_id": clientID, "client_secret": clientSecret, "redirect_uri": redirectURI, "grant_type": "refresh_token"]
        request.httpBody = try? JSONEncoder().encode(body)

        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 200, let token = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) { persistTokens(token) } else if http.statusCode == 401 { logout() }
    }

    func logout() { accessToken = ""; refreshToken = nil; expiresAt = nil; Keychain.delete(Key.access); Keychain.delete(Key.refresh); Keychain.delete(Key.expiry); isAuthenticating = false }
    
    enum ScrobbleAction: String { case start = "start", pause = "pause", stop = "stop" }
    
    func scrobble(item: MediaItem, progress: Double, action: ScrobbleAction) {
        guard isAuthenticated, let metadata = item.metadata, metadata.tmdbID > 0 else { return }
        let url = URL(string: "https://api.trakt.tv/scrobble/\(action.rawValue)")!
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("2", forHTTPHeaderField: "trakt-api-version"); request.setValue(clientID, forHTTPHeaderField: "trakt-api-key"); request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        var payload: [String: Any] = ["progress": progress * 100, "app_version": "1.0", "app_date": "2024-01-01"]
        if metadata.isTVShow {
            payload["episode"] = ["season": metadata.season ?? 1, "number": metadata.episode ?? 1]
            payload["show"] = ["ids": ["tmdb": metadata.tmdbID]]
        } else {
            payload["movie"] = ["title": metadata.title, "year": Int(metadata.releaseYear) ?? 0, "ids": ["tmdb": metadata.tmdbID]]
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let scrobbleRequest = request
        Task.detached { try? await URLSession.shared.data(for: scrobbleRequest) }
    }
}

// ============================================================
// TMDB Metadata Models & Service
// ============================================================

struct CastMember: Codable, Hashable {
    let name: String
    let profileURL: URL?
}

struct MediaMetadata: Codable, Hashable {
    var tmdbID: Int; var title: String; var overview: String; var posterURL: URL?; var backdropURL: URL?; var releaseYear: String; var isTVShow: Bool; var season: Int?; var episode: Int?; var rating: Double?
    var genres: [String] = []
    var cast: [CastMember] = []
}

struct TMDBResponse: Codable { let results: [TMDBResult] }
struct TMDBResult: Codable { let id: Int; let title: String?; let name: String?; let overview: String?; let poster_path: String?; let backdrop_path: String?; let release_date: String?; let first_air_date: String? }
struct TMDBDetailResponse: Codable { let vote_average: Double?; let genres: [TMDBGenre]?; let credits: TMDBCredits? }
struct TMDBGenre: Codable { let name: String }
struct TMDBCredits: Codable { let cast: [TMDBCast]? }
struct TMDBCast: Codable { let name: String; let profile_path: String? }

final class MetadataService {
    static var apiKey: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"), let dict = NSDictionary(contentsOfFile: path) as? [String: Any], let key = dict["TMDBAPIKey"] as? String else { return "" }
        return key
    }
    static let baseURL = "https://api.themoviedb.org/3"
    static let imageBaseURL = "https://image.tmdb.org/t/p/w780"
    static let profileBaseURL = "https://image.tmdb.org/t/p/w185"
    
    static func fetchMetadata(for filename: String, cleanTitle: String) async -> MediaMetadata? {
        guard !apiKey.isEmpty else { return nil }
        
        let isTV = filename.localizedStandardContains("S0") || filename.localizedStandardContains("E0") || filename.localizedStandardContains("Season")
        let searchType = isTV ? "tv" : "movie"
        
        var season: Int? = nil; var episode: Int? = nil
        if isTV {
            let pattern = "[sS](\\d{1,2})[eE](\\d{1,2})"
            if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) {
                if let sRange = Range(match.range(at: 1), in: filename), let eRange = Range(match.range(at: 2), in: filename) { season = Int(filename[sRange]); episode = Int(filename[eRange]) }
            }
        }
        
        var searchTitle = cleanTitle; var explicitYear: String? = nil
        let yearPattern = "\\b(19\\d{2}|20[0-2]\\d|2030)\\b"
        if let regex = try? NSRegularExpression(pattern: yearPattern), let match = regex.firstMatch(in: cleanTitle, range: NSRange(cleanTitle.startIndex..., in: cleanTitle)), let yearRange = Range(match.range, in: cleanTitle) {
            explicitYear = String(cleanTitle[yearRange])
            searchTitle = cleanTitle.replacingCharacters(in: yearRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var components = URLComponents(string: "\(baseURL)/search/\(searchType)")!
        var queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "query", value: searchTitle), URLQueryItem(name: "page", value: "1")]
        if let year = explicitYear { queryItems.append(URLQueryItem(name: isTV ? "first_air_date_year" : "year", value: year)) }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TMDBResponse.self, from: data)
            guard let firstResult = response.results.first else { return nil }
            
            let dateString = firstResult.release_date ?? firstResult.first_air_date ?? ""
            let year = String(dateString.prefix(4))
            
            var posterURL: URL? = nil; if let path = firstResult.poster_path { posterURL = URL(string: "\(imageBaseURL)\(path)") }
            var backdropURL: URL? = nil; if let path = firstResult.backdrop_path { backdropURL = URL(string: "\(imageBaseURL)\(path)") }
            
            var rating: Double? = nil; var genres: [String] = []; var cast: [CastMember] = []
            let detailsURLStr = "\(baseURL)/\(searchType)/\(firstResult.id)?api_key=\(apiKey)&append_to_response=credits"
            if let dUrl = URL(string: detailsURLStr), let (dData, _) = try? await URLSession.shared.data(from: dUrl), let details = try? JSONDecoder().decode(TMDBDetailResponse.self, from: dData) {
                rating = details.vote_average
                genres = details.genres?.prefix(3).map { $0.name } ?? []
                cast = details.credits?.cast?.prefix(15).map { CastMember(name: $0.name, profileURL: $0.profile_path != nil ? URL(string: "\(profileBaseURL)\($0.profile_path!)") : nil) } ?? []
            }
            
            return MediaMetadata(tmdbID: firstResult.id, title: firstResult.title ?? firstResult.name ?? cleanTitle, overview: firstResult.overview ?? "No description available.", posterURL: posterURL, backdropURL: backdropURL, releaseYear: year, isTVShow: isTV, season: season, episode: episode, rating: rating, genres: genres, cast: cast)
        } catch { return nil }
    }
}

// ============================================================
// Models
// ============================================================

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
    var fileBookmark: Data? = nil // Support for external folder sync files

    var progress: Double { guard duration > 0 else { return 0 }; return min(max(lastPosition / duration, 0), 1) }
    var isWatched: Bool { duration > 0 && progress >= 0.95 }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    var isAudio: Bool { MediaKinds.audio.contains(fileExtension) }
    var isEngineSupported: Bool { MediaKinds.native.contains(fileExtension) }
}

// Netflix-style Unified Display Model for the Grid
enum LibraryElement: Identifiable, Hashable {
    case movie(MediaItem)
    case tvShow(seriesTitle: String, episodes: [MediaItem])
    
    var id: String {
        switch self {
        case .movie(let i): return i.id.uuidString
        case .tvShow(let t, _): return "tv_\(t)"
        }
    }
    var title: String {
        switch self {
        case .movie(let i): return i.metadata?.title ?? i.title
        case .tvShow(let t, _): return t
        }
    }
    var dateAdded: Date {
        switch self {
        case .movie(let i): return i.dateAdded
        case .tvShow(_, let eps): return eps.map(\.dateAdded).max() ?? .distantPast
        }
    }
    var lastPlayed: Date? {
        switch self {
        case .movie(let i): return i.lastPlayed
        case .tvShow(_, let eps): return eps.compactMap(\.lastPlayed).max()
        }
    }
    var primaryItem: MediaItem {
        switch self {
        case .movie(let i): return i
        case .tvShow(_, let eps): return eps.first!
        }
    }
}

// ============================================================
// LibraryStore
// ============================================================

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var linkedFolderBookmarks: [Data] = []
    
    private let fm = FileManager.default
    let documentsURL: URL; let mediaDir: URL; let thumbsDir: URL; private let indexURL: URL; private let foldersURL: URL

    init() {
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mediaDir = documentsURL.appendingPathComponent("Media", isDirectory: true)
        thumbsDir = documentsURL.appendingPathComponent("Thumbnails", isDirectory: true)
        indexURL = documentsURL.appendingPathComponent("library.json")
        foldersURL = documentsURL.appendingPathComponent("linked_folders.json")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) { items = decoded }
        if let data = try? Data(contentsOf: foldersURL), let decoded = try? JSONDecoder().decode([Data].self, from: data) { linkedFolderBookmarks = decoded }
    }
    func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
        if let data = try? JSONEncoder().encode(linkedFolderBookmarks) { try? data.write(to: foldersURL, options: .atomic) }
    }

    func url(for item: MediaItem) -> URL? {
        if let bookmark = item.fileBookmark {
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        return mediaDir.appendingPathComponent(item.fileName)
    }
    func thumbURL(for item: MediaItem) -> URL { thumbsDir.appendingPathComponent(item.id.uuidString + ".jpg") }

    private func uniqueDestination(for fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension; let ext = (fileName as NSString).pathExtension
        var dest = mediaDir.appendingPathComponent(fileName); var counter = 1
        while fm.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            dest = mediaDir.appendingPathComponent(name); counter += 1
        }
        return dest
    }

    func linkFolders(_ urls: [URL]) async {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            if let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                linkedFolderBookmarks.append(bookmark)
            }
            url.stopAccessingSecurityScopedResource()
        }
        save()
        await rescan()
    }

    func importFiles(_ urls: [URL]) async { for url in urls { await importFile(url) }; save() }

    func importFile(_ src: URL) async {
        let secured = src.startAccessingSecurityScopedResource(); defer { if secured { src.stopAccessingSecurityScopedResource() } }
        let ext = src.pathExtension.lowercased()
        if MediaKinds.subtitles.contains(ext) {
            let dest = mediaDir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dest); try? fm.copyItem(at: src, to: dest)
            return
        }
        guard MediaKinds.media.contains(ext) else { return }
        let dest = uniqueDestination(for: src.lastPathComponent)
        do { let from = src; let to = dest; try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: from, to: to) }.value } catch { return }
        if src.path.contains("/Inbox/") { try? fm.removeItem(at: src) }
        await ingest(fileURL: dest, isExternal: false); save()
    }

    private func ingest(fileURL: URL, isExternal: Bool) async {
        let rawTitle = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let prettyTitle = Self.prettyTitle(from: rawTitle)
        var item = MediaItem(title: prettyTitle, fileName: fileURL.lastPathComponent)
        
        if isExternal { item.fileBookmark = try? fileURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        
        if let meta = await MetadataService.fetchMetadata(for: fileURL.lastPathComponent, cleanTitle: prettyTitle) { item.metadata = meta }

        let secured = isExternal ? fileURL.startAccessingSecurityScopedResource() : false
        let asset = AVURLAsset(url: fileURL)
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { item.duration = d.seconds }
        if secured { fileURL.stopAccessingSecurityScopedResource() }
        
        if !item.isAudio {
            let seconds = item.duration > 0 ? max(1.0, item.duration * 0.12) : 3.0
            await Self.writeThumbnail(assetURL: fileURL, at: seconds, to: thumbURL(for: item), isExternal: isExternal)
        }
        items.insert(item, at: 0)
    }

    func rescan() async {
        var changed = false
        
        // 1. Scan app documents
        if let loose = try? fm.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
            for f in loose {
                let ext = f.pathExtension.lowercased()
                if MediaKinds.subtitles.contains(ext) { let dest = mediaDir.appendingPathComponent(f.lastPathComponent); try? fm.removeItem(at: dest); try? fm.moveItem(at: f, to: dest) }
                else if MediaKinds.media.contains(ext) { let dest = uniqueDestination(for: f.lastPathComponent); try? fm.moveItem(at: f, to: dest) }
            }
        }
        if let files = try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
            for f in files {
                guard MediaKinds.media.contains(f.pathExtension.lowercased()) else { continue }
                guard !items.contains(where: { $0.fileName == f.lastPathComponent && $0.fileBookmark == nil }) else { continue }
                await ingest(fileURL: f, isExternal: false); changed = true
            }
        }
        
        // 2. Scan External Linked Folders
        for bookmark in linkedFolderBookmarks {
            var stale = false
            guard let folderURL = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if folderURL.startAccessingSecurityScopedResource() {
                let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                while let fileURL = enumerator?.nextObject() as? URL {
                    guard MediaKinds.media.contains(fileURL.pathExtension.lowercased()) else { continue }
                    // Match external files by exact name to avoid duplicates
                    if !items.contains(where: { $0.fileName == fileURL.lastPathComponent && $0.fileBookmark != nil }) {
                        await ingest(fileURL: fileURL, isExternal: true); changed = true
                    }
                }
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        // Cleanup deleted local files
        let before = items.count
        items.removeAll { 
            if $0.fileBookmark != nil { return false } // Don't wipe offline external drive files
            guard let u = url(for: $0) else { return true }
            return !fm.fileExists(atPath: u.path) 
        }
        if changed || items.count != before { save() }
    }

    func updateProgress(id: UUID, position: Double, duration: Double) { guard let i = items.firstIndex(where: { $0.id == id }) else { return }; items[i].lastPosition = max(0, position); if duration > 0, duration.isFinite { items[i].duration = duration }; items[i].lastPlayed = Date(); save() }
    func resetProgress(_ item: MediaItem) { guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }; items[i].lastPosition = 0; save() }
    func markWatched(_ item: MediaItem) { guard let i = items.firstIndex(where: { $0.id == item.id }), items[i].duration > 0 else { return }; items[i].lastPosition = items[i].duration; items[i].lastPlayed = Date(); save() }
    func rename(_ item: MediaItem, to newTitle: String) { let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty, let i = items.firstIndex(where: { $0.id == item.id }) else { return }; items[i].title = trimmed; save() }
    func delete(_ item: MediaItem) { 
        if let u = url(for: item) { try? fm.removeItem(at: u); let sidecar = u.deletingPathExtension().appendingPathExtension("srt"); try? fm.removeItem(at: sidecar) }
        try? fm.removeItem(at: thumbURL(for: item)); items.removeAll { $0.id == item.id }; save() 
    }
    func clearProgress() { for i in items.indices { items[i].lastPosition = 0; items[i].lastPlayed = nil }; save() }
    func deleteAll() { for item in items { if let u = url(for: item) { try? fm.removeItem(at: u) }; try? fm.removeItem(at: thumbURL(for: item)) }; items.removeAll(); linkedFolderBookmarks.removeAll(); save() }
    func storageString() -> String { var total: Int64 = 0; if let enumerator = fm.enumerator(at: mediaDir, includingPropertiesForKeys: [.fileSizeKey]) { for case let f as URL in enumerator { if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) } } }; return ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }

    static func prettyTitle(from raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " "); if !s.contains(" ") { s = s.replacingOccurrences(of: ".", with: " ") }
        let lower = s.lowercased(); let markers = ["1080p", "720p", "2160p", "480p", "4k", "x264", "x265", "h264", "h265", "hevc", "web-dl", "webdl", "webrip", "bluray", "brrip", "bdrip", "hdrip", "hdtv", "dvdrip", "remux", "10bit", "yify", "rarbg", "aac"]
        var cut = s.count; for m in markers { if let r = lower.range(of: m) { cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound)) } }; if cut < s.count { s = String(s.prefix(cut)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -._[]()"))
        let pattern = "(?i)s\\d{1,2}e\\d{1,2}.*"
        if let regex = try? NSRegularExpression(pattern: pattern) { s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return s.isEmpty ? raw : s
    }

    nonisolated static func writeThumbnail(assetURL: URL, at seconds: Double, to dest: URL, isExternal: Bool) async {
        let secured = isExternal ? assetURL.startAccessingSecurityScopedResource() : false
        defer { if secured { assetURL.stopAccessingSecurityScopedResource() } }
        await Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: assetURL)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 720, height: 720); generator.requestedTimeToleranceBefore = .positiveInfinity; generator.requestedTimeToleranceAfter = .positiveInfinity
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
            let image = UIImage(cgImage: cg); guard let data = image.jpegData(compressionQuality: 0.75) else { return }; try? data.write(to: dest, options: .atomic)
        }.value
    }
}

func formatTime(_ t: Double) -> String { guard t.isFinite, t >= 0 else { return "0:00" }; let total = Int(t.rounded()); let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60; return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s) }

// ============================================================
// Subtitles
// ============================================================

struct SubtitleCue { let start: Double; let end: Double; let text: String }
enum SRTParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]), let end = timestamp(parts[1]) else { continue }
            let clean = lines[(timeIndex + 1)...].joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: clean))
        }
        return cues.sorted { $0.start < $1.start }
    }
    static func timestamp(_ raw: String) -> Double? {
        var t = raw.trimmingCharacters(in: .whitespaces); if let space = t.firstIndex(of: " ") { t = String(t[..<space]) }
        t = t.replacingOccurrences(of: ",", with: "."); let comps = t.split(separator: ":"); guard comps.count >= 2 else { return nil }
        let numbers = comps.compactMap { Double($0) }; guard numbers.count == comps.count else { return nil }
        return numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
    }
    static func cue(at time: Double, in cues: [SubtitleCue]) -> String? {
        for cue in cues { if time >= cue.start && time <= cue.end { return cue.text }; if cue.start > time { break } }
        return nil
    }
}

// ============================================================
// Player Layers
// ============================================================

final class PlayerLayerHolder { weak var playerLayer: AVPlayerLayer? }
final class PlayerContainerView: UIView { override static var layerClass: AnyClass { AVPlayerLayer.self }; var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } }
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer; let holder: PlayerLayerHolder; let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerContainerView { let view = PlayerContainerView(); view.backgroundColor = .black; view.playerLayer.player = player; view.playerLayer.videoGravity = gravity; holder.playerLayer = view.playerLayer; return view }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) { uiView.playerLayer.videoGravity = gravity }
}
struct VLCPlayerLayerView: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) { player.drawable = uiView }
}
