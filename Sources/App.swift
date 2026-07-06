//
//  App.swift - Mina Anii (fixed)
//
//  IMPORTANT: This file now contains the ONLY copy of TraktService.
//  Delete Sources/TraktService.swift from the project, otherwise the build
//  fails with "Invalid redeclaration of 'TraktService'".
//
//  Changes in this version:
//   1. (Build-breaker) TraktService/models exist here once; the duplicate file must be removed.
//   2. Trakt tokens now stored in the Keychain instead of UserDefaults (plaintext).
//   3. Refresh-token support added: the session refreshes instead of silently expiring (~3 months).
//   4. Device-flow polling now honours the spec (authorization_pending / slow_down / denied / expired).
//   5. Removed the duplicate "start" scrobble fired every time a video opened.
//   6. TV-vs-movie detection rewritten around the SxxExx regex (handles S10+, no false positives).
//
//  Separately (not code): rotate the leaked TMDB key + Trakt client ID/secret, and keep
//  Secrets.plist out of git (it is already in .gitignore; remove it from history / re-cache it).
//

import Foundation
import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit
import UniformTypeIdentifiers
import MobileVLCKit
import Security

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
                    Task {
                        await store.importFile(url)
                        store.save()
                    }
                }
        }
    }
}

// ============================================================
// Trakt Models & Service
// ============================================================

// Minimal Keychain wrapper so OAuth tokens are never stored in plaintext (UserDefaults).
enum Keychain {
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct TraktDeviceCodeResponse: Codable {
    let device_code: String
    let user_code: String
    let verification_url: String
    let expires_in: Int
    let interval: Int
}

// Trakt device-token responses also include refresh_token / expires_in / created_at,
// which we keep so the session can be refreshed instead of silently expiring (~3 months).
struct TraktTokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let created_at: Int?
}

@MainActor
final class TraktService: ObservableObject {
    static let shared = TraktService()

    private enum Key {
        static let access = "trakt.accessToken"
        static let refresh = "trakt.refreshToken"
        static let expiry = "trakt.expiresAt"
    }

    private var clientID: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["TraktClientID"] as? String else { return "" }
        return key
    }
    
    private var clientSecret: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["TraktClientSecret"] as? String else { return "" }
        return key
    }

    @Published private(set) var accessToken: String
    private var refreshToken: String?
    private var expiresAt: Date?

    @Published var isAuthenticating = false
    @Published var authUserCode: String?
    @Published var authVerificationURL: String?

    var isAuthenticated: Bool { !accessToken.isEmpty }
    private var authTask: Task<Void, Never>?

    private init() {
        accessToken = Keychain.get(Key.access) ?? ""
        refreshToken = Keychain.get(Key.refresh)
        if let raw = Keychain.get(Key.expiry), let ts = Double(raw) {
            expiresAt = Date(timeIntervalSince1970: ts)
        }
    }

    private func persistTokens(_ token: TraktTokenResponse) {
        accessToken = token.access_token
        Keychain.set(token.access_token, for: Key.access)
        if let refresh = token.refresh_token {
            refreshToken = refresh
            Keychain.set(refresh, for: Key.refresh)
        }
        if let expiresIn = token.expires_in {
            let base = token.created_at.map(Double.init) ?? Date().timeIntervalSince1970
            let expiry = base + Double(expiresIn)
            expiresAt = Date(timeIntervalSince1970: expiry)
            Keychain.set(String(expiry), for: Key.expiry)
        }
    }

    func startDeviceAuthentication() async {
        guard !clientID.isEmpty else {
            print("Trakt Error: Missing Client ID in Secrets.plist")
            return
        }
        
        isAuthenticating = true
        guard let url = URL(string: "https://api.trakt.tv/oauth/device/code") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = ["client_id": clientID]
        request.httpBody = try? JSONEncoder().encode(body)
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(TraktDeviceCodeResponse.self, from: data)
            self.authUserCode = response.user_code
            self.authVerificationURL = response.verification_url
            pollForToken(deviceCode: response.device_code, interval: response.interval, expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
        } catch {
            print("Trakt Device Code Error: \(error)")
            isAuthenticating = false
        }
    }
    
    private func pollForToken(deviceCode: String, interval: Int, expiresAt: Date) {
        authTask?.cancel()
        authTask = Task {
            var delay = interval
            while Date() < expiresAt {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                
                guard let url = URL(string: "https://api.trakt.tv/oauth/device/token") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let body: [String: String] = ["code": deviceCode, "client_id": clientID, "client_secret": clientSecret]
                request.httpBody = try? JSONEncoder().encode(body)
                
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let httpResponse = response as? HTTPURLResponse else { continue }

                switch httpResponse.statusCode {
                case 200:
                    if let tokenData = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) {
                        self.persistTokens(tokenData)
                        self.isAuthenticating = false
                        self.authUserCode = nil
                        return
                    }
                case 400:
                    // authorization_pending: keep polling at the normal interval.
                    continue
                case 429:
                    // slow_down: back off as required by the device-flow spec.
                    delay += 1
                    continue
                default:
                    // expired_token (410), access_denied (403), etc. Stop cleanly.
                    self.isAuthenticating = false
                    self.authUserCode = nil
                    return
                }
            }
            self.isAuthenticating = false
        }
    }

    // Proactively refresh the access token before it lapses so the user stays signed in.
    func refreshIfNeeded() async {
        guard !accessToken.isEmpty, let refreshToken, let expiresAt else { return }
        guard Date() > expiresAt.addingTimeInterval(-7 * 24 * 3600) else { return }
        guard let url = URL(string: "https://api.trakt.tv/oauth/token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token"
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 200, let token = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) {
            persistTokens(token)
        } else if http.statusCode == 401 {
            // Refresh token no longer valid; clear the stale session.
            logout()
        }
    }

    func logout() {
        authTask?.cancel()
        accessToken = ""
        refreshToken = nil
        expiresAt = nil
        Keychain.delete(Key.access)
        Keychain.delete(Key.refresh)
        Keychain.delete(Key.expiry)
        isAuthenticating = false
    }
    
    enum ScrobbleAction: String { case start = "start", pause = "pause", stop = "stop" }
    
    func scrobble(item: MediaItem, progress: Double, action: ScrobbleAction) {
        guard isAuthenticated, let metadata = item.metadata, metadata.tmdbID > 0 else { return }
        
        let url = URL(string: "https://api.trakt.tv/scrobble/\(action.rawValue)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        var payload: [String: Any] = ["progress": progress * 100, "app_version": "1.0", "app_date": "2024-01-01"]
        
        if metadata.isTVShow {
            payload["episode"] = ["season": metadata.season ?? 1, "number": metadata.episode ?? 1]
            payload["show"] = ["ids": ["tmdb": metadata.tmdbID]]
        } else {
            payload["movie"] = ["title": metadata.title, "year": Int(metadata.releaseYear) ?? 0, "ids": ["tmdb": metadata.tmdbID]]
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let scrobbleRequest = request

        Task.detached {
            do {
                let (_, response) = try await URLSession.shared.data(for: scrobbleRequest)
                if let httpResponse = response as? HTTPURLResponse {
                    print("Trakt Scrobble (\(action.rawValue)) Status: \(httpResponse.statusCode)")
                }
            } catch {
                print("Trakt Scrobble Error: \(error)")
            }
        }
    }
}

// ============================================================
// TMDB Metadata Models & Service
// ============================================================

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
    var cast: [String] = []
}

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
}

struct TMDBDetailResponse: Codable {
    let vote_average: Double?
    let genres: [TMDBGenre]?
    let credits: TMDBCredits?
}
struct TMDBGenre: Codable { let name: String }
struct TMDBCredits: Codable { let cast: [TMDBCast]? }
struct TMDBCast: Codable { let name: String }

final class MetadataService {
    static var apiKey: String {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = dict["TMDBAPIKey"] as? String else { return "" }
        return key
    }
    
    static let baseURL = "https://api.themoviedb.org/3"
    static let imageBaseURL = "https://image.tmdb.org/t/p/w780"
    
    static func fetchMetadata(for filename: String, cleanTitle: String) async -> MediaMetadata? {
        // Derive season/episode from a proper SxxExx pattern first (handles S10E01, etc.),
        // then decide TV vs movie from that, which avoids false positives like a movie named "S0mething".
        var season: Int? = nil
        var episode: Int? = nil
        let episodePattern = "[sS](\\d{1,2})[eE](\\d{1,2})"
        if let regex = try? NSRegularExpression(pattern: episodePattern),
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let sRange = Range(match.range(at: 1), in: filename),
           let eRange = Range(match.range(at: 2), in: filename) {
            season = Int(filename[sRange])
            episode = Int(filename[eRange])
        }

        let hasSeasonKeyword = filename.range(of: "season\\s*\\d", options: [.regularExpression, .caseInsensitive]) != nil
        let isTV = season != nil || hasSeasonKeyword
        let searchType = isTV ? "tv" : "movie"
        
        var components = URLComponents(string: "\(baseURL)/search/\(searchType)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: cleanTitle),
            URLQueryItem(name: "page", value: "1")
        ]
        guard let url = components.url else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TMDBResponse.self, from: data)
            guard let firstResult = response.results.first else { return nil }
            
            let dateString = firstResult.release_date ?? firstResult.first_air_date ?? ""
            let year = String(dateString.prefix(4))
            
            var posterURL: URL? = nil
            if let path = firstResult.poster_path { posterURL = URL(string: "\(imageBaseURL)\(path)") }
            
            var backdropURL: URL? = nil
            if let path = firstResult.backdrop_path { backdropURL = URL(string: "\(imageBaseURL)\(path)") }
            
            var rating: Double? = nil
            var genres: [String] = []
            var cast: [String] = []
            
            let detailsURLStr = "\(baseURL)/\(searchType)/\(firstResult.id)?api_key=\(apiKey)&append_to_response=credits"
            if let dUrl = URL(string: detailsURLStr),
               let (dData, _) = try? await URLSession.shared.data(from: dUrl),
               let details = try? JSONDecoder().decode(TMDBDetailResponse.self, from: dData) {
                
                rating = details.vote_average
                genres = details.genres?.prefix(3).map { $0.name } ?? []
                cast = details.credits?.cast?.prefix(10).map { $0.name } ?? []
            }
            
            return MediaMetadata(
                tmdbID: firstResult.id,
                title: firstResult.title ?? firstResult.name ?? cleanTitle,
                overview: firstResult.overview ?? "No description available.",
                posterURL: posterURL,
                backdropURL: backdropURL,
                releaseYear: year,
                isTVShow: isTV,
                season: season,
                episode: episode,
                rating: rating,
                genres: genres,
                cast: cast
            )
        } catch {
            print("TMDB Fetch Error: \(error.localizedDescription)")
            return nil
        }
    }
}

// ============================================================
// Local Models
// ============================================================

enum MediaKinds {
    static let video: Set<String> = [
        "mp4", "m4v", "mov", "3gp", "mkv", "avi", "webm", "ts", "m2ts",
        "mts", "flv", "wmv", "mpg", "mpeg", "vob", "ogv"
    ]
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

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(lastPosition / duration, 0), 1)
    }

    var isWatched: Bool { duration > 0 && progress >= 0.95 }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    var isAudio: Bool { MediaKinds.audio.contains(fileExtension) }
    var isEngineSupported: Bool { MediaKinds.native.contains(fileExtension) }
}

// ============================================================
// LibraryStore
// ============================================================

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    private let fm = FileManager.default
    let documentsURL: URL
    let mediaDir: URL
    let thumbsDir: URL
    private let indexURL: URL

    init() {
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mediaDir = documentsURL.appendingPathComponent("Media", isDirectory: true)
        thumbsDir = documentsURL.appendingPathComponent("Thumbnails", isDirectory: true)
        indexURL = documentsURL.appendingPathComponent("library.json")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func url(for item: MediaItem) -> URL { mediaDir.appendingPathComponent(item.fileName) }
    func thumbURL(for item: MediaItem) -> URL { thumbsDir.appendingPathComponent(item.id.uuidString + ".jpg") }

    private func uniqueDestination(for fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var dest = mediaDir.appendingPathComponent(fileName)
        var counter = 1
        while fm.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            dest = mediaDir.appendingPathComponent(name)
            counter += 1
        }
        return dest
    }

    func importFiles(_ urls: [URL]) async {
        for url in urls { await importFile(url) }
        save()
    }

    func importFile(_ src: URL) async {
        let secured = src.startAccessingSecurityScopedResource()
        defer { if secured { src.stopAccessingSecurityScopedResource() } }

        let ext = src.pathExtension.lowercased()
        if MediaKinds.subtitles.contains(ext) {
            let dest = mediaDir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: src, to: dest)
            return
        }

        guard MediaKinds.media.contains(ext) else { return }

        let dest = uniqueDestination(for: src.lastPathComponent)
        do {
            let from = src; let to = dest
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: from, to: to) }.value
        } catch { return }

        if src.path.contains("/Inbox/") { try? fm.removeItem(at: src) }
        await ingest(fileURL: dest)
        save()
    }

    private func ingest(fileURL: URL) async {
        let rawTitle = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let prettyTitle = Self.prettyTitle(from: rawTitle)
        
        var item = MediaItem(title: prettyTitle, fileName: fileURL.lastPathComponent)
        
        if let meta = await MetadataService.fetchMetadata(for: fileURL.lastPathComponent, cleanTitle: prettyTitle) {
            item.metadata = meta
        }

        let asset = AVURLAsset(url: fileURL)
        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { item.duration = d.seconds }
        if !item.isAudio {
            let seconds = item.duration > 0 ? max(1.0, item.duration * 0.12) : 3.0
            await Self.writeThumbnail(assetURL: fileURL, at: seconds, to: thumbURL(for: item))
        }
        items.insert(item, at: 0)
    }

    func rescan() async {
        var changed = false
        if let loose = try? fm.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
            for f in loose {
                let ext = f.pathExtension.lowercased()
                if MediaKinds.subtitles.contains(ext) {
                    let dest = mediaDir.appendingPathComponent(f.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    try? fm.moveItem(at: f, to: dest)
                } else if MediaKinds.media.contains(ext) {
                    let dest = uniqueDestination(for: f.lastPathComponent)
                    try? fm.moveItem(at: f, to: dest)
                }
            }
        }

        if let files = try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
            for f in files {
                let ext = f.pathExtension.lowercased()
                guard MediaKinds.media.contains(ext) else { continue }
                guard !items.contains(where: { $0.fileName == f.lastPathComponent }) else { continue }
                await ingest(fileURL: f)
                changed = true
            }
        }
        let before = items.count
        items.removeAll { !fm.fileExists(atPath: url(for: $0).path) }
        if changed || items.count != before { save() }
    }

    func updateProgress(id: UUID, position: Double, duration: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastPosition = max(0, position)
        if duration > 0, duration.isFinite { items[i].duration = duration }
        items[i].lastPlayed = Date()
        save()
    }

    func resetProgress(_ item: MediaItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].lastPosition = 0
        save()
    }

    func markWatched(_ item: MediaItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), items[i].duration > 0 else { return }
        items[i].lastPosition = items[i].duration
        items[i].lastPlayed = Date()
        save()
    }

    func rename(_ item: MediaItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].title = trimmed
        save()
    }

    func delete(_ item: MediaItem) {
        try? fm.removeItem(at: url(for: item))
        try? fm.removeItem(at: thumbURL(for: item))
        let sidecar = url(for: item).deletingPathExtension().appendingPathExtension("srt")
        try? fm.removeItem(at: sidecar)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearProgress() {
        for i in items.indices { items[i].lastPosition = 0; items[i].lastPlayed = nil }
        save()
    }

    func deleteAll() {
        for item in items { try? fm.removeItem(at: url(for: item)); try? fm.removeItem(at: thumbURL(for: item)) }
        items.removeAll()
        save()
    }

    func storageString() -> String {
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: mediaDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in enumerator {
                if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    static func prettyTitle(from raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        if !s.contains(" ") { s = s.replacingOccurrences(of: ".", with: " ") }
        let lower = s.lowercased()
        let markers = ["1080p", "720p", "2160p", "480p", "4k", "x264", "x265", "h264", "h265", "hevc", "web-dl", "webdl", "webrip", "bluray", "brrip", "bdrip", "hdrip", "hdtv", "dvdrip", "remux", "10bit", "yify", "rarbg", "aac"]
        var cut = s.count
        for m in markers {
            if let r = lower.range(of: m) { cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound)) }
        }
        if cut < s.count { s = String(s.prefix(cut)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -._[]()"))
        
        let pattern = "(?i)s\\d{1,2}e\\d{1,2}.*"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? raw : s
    }

    nonisolated static func writeThumbnail(assetURL: URL, at seconds: Double, to dest: URL) async {
        await Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: assetURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
            let image = UIImage(cgImage: cg)
            guard let data = image.jpegData(compressionQuality: 0.75) else { return }
            try? data.write(to: dest, options: .atomic)
        }.value
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let total = Int(t.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

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
            let clean = lines[(timeIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: clean))
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func timestamp(_ raw: String) -> Double? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let space = t.firstIndex(of: " ") { t = String(t[..<space]) }
        t = t.replacingOccurrences(of: ",", with: ".")
        let comps = t.split(separator: ":")
        guard comps.count >= 2 else { return nil }
        let numbers = comps.compactMap { Double($0) }
        guard numbers.count == comps.count else { return nil }
        return numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
    }

    static func cue(at time: Double, in cues: [SubtitleCue]) -> String? {
        for cue in cues {
            if time >= cue.start && time <= cue.end { return cue.text }
            if cue.start > time { break }
        }
        return nil
    }
}

// ============================================================
// Player Layers
// ============================================================

final class PlayerLayerHolder { weak var playerLayer: AVPlayerLayer? }

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer; let holder: PlayerLayerHolder; let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black; view.playerLayer.player = player; view.playerLayer.videoGravity = gravity
        holder.playerLayer = view.playerLayer; return view
    }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) { uiView.playerLayer.videoGravity = gravity }
}

struct VLCPlayerLayerView: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; player.drawable = view; return view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = .systemPurple; view.prioritizesVideoDevices = true; return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// ============================================================
// PlayerVM & PlayerScreen
// ============================================================

@MainActor
final class PlayerVM: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let store: LibraryStore
    let media: MediaItem
    let player = AVPlayer()
    let layerHolder = PlayerLayerHolder()
    let vlcPlayer = VLCMediaPlayer()

    @Published var isPlaying = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1.0
    @Published var showControls = true
    @Published var isScrubbing = false
    @Published var fillScreen = false
    @Published var cueText: String?
    @Published var subtitlesOn = true
    @Published var hasExternalCues = false
    @Published var errorMessage: String?
    @Published var audioOptions: [AVMediaSelectionOption] = []
    @Published var legibleOptions: [AVMediaSelectionOption] = []
    @Published var volumeLevel: Double = 1.0
    @Published var flashText: String?
    
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var lastSave = Date.distantPast
    private var hideTask: DispatchWorkItem?
    private var flashTask: DispatchWorkItem?
    private var pip: AVPictureInPictureController?
    private var pendingVLCSeek: Double?

    init(media: MediaItem, store: LibraryStore) { self.media = media; self.store = store; super.init() }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback); try? session.setActive(true)

        let url = store.url(for: media)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "defaultRate") != nil { rate = defaults.double(forKey: "defaultRate") }
        if rate <= 0 { rate = 1 }

        let autoResume = (defaults.object(forKey: "autoResume") as? Bool) ?? true
        let shouldResume = autoResume && media.lastPosition > 15 && media.duration > 0 && media.lastPosition < media.duration * 0.95

        if media.isEngineSupported {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item); player.allowsExternalPlayback = true; player.volume = Float(volumeLevel)

            statusCancellable = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
                guard let self else { return }
                if status == .readyToPlay, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }

            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isPlaying = false; self.showControls = true
                if self.duration > 0 { self.store.updateProgress(id: self.media.id, position: self.duration, duration: self.duration) }
            }

            loadSelectionGroups(for: item)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                guard let self, !self.isScrubbing else { return }
                self.current = time.seconds
                if self.duration <= 0, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.cueText = (self.subtitlesOn && self.hasExternalCues) ? SRTParser.cue(at: time.seconds, in: self.cues) : nil
                self.periodicSave()
            }
            if shouldResume { player.seek(to: CMTime(seconds: media.lastPosition, preferredTimescale: 600)); current = media.lastPosition }
        } else {
            vlcPlayer.delegate = self; vlcPlayer.media = VLCMedia(url: url); vlcPlayer.audio?.volume = Int32(volumeLevel * 100)
            if shouldResume { self.pendingVLCSeek = media.lastPosition }
        }

        loadSidecarSubtitles(for: url)
        play()   // play() already emits the Trakt "start" scrobble; no duplicate call here.
        scheduleAutoHide()
    }

    func stop() {
        saveNow()
        let prog = duration > 0 ? (current / duration) : 0
        TraktService.shared.scrobble(item: media, progress: prog, action: .stop)
        
        statusCancellable = nil
        if let observer = timeObserver { player.removeTimeObserver(observer); timeObserver = nil }
        if let end = endObserver { NotificationCenter.default.removeObserver(end); endObserver = nil }
        hideTask?.cancel(); flashTask?.cancel()
        
        if media.isEngineSupported { player.pause(); player.replaceCurrentItem(with: nil) } 
        else { vlcPlayer.stop(); vlcPlayer.delegate = nil }
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification!) {
        Task { @MainActor in
            switch self.vlcPlayer.state {
            case .playing:
                self.isPlaying = true
                if let dur = self.vlcPlayer.media?.length.value?.doubleValue, dur > 0, self.duration <= 0 { self.duration = dur / 1000.0 }
                if let target = self.pendingVLCSeek { self.vlcPlayer.time = VLCTime(int: Int32(target * 1000)); self.current = target; self.pendingVLCSeek = nil }
            case .paused: self.isPlaying = false
            case .ended:
                self.isPlaying = false; self.showControls = true
                if self.duration > 0 { self.store.updateProgress(id: self.media.id, position: self.duration, duration: self.duration) }
            case .error: self.errorMessage = "VLC encountered an error reading this file. It may be corrupted."
            default: break
            }
        }
    }
    
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        Task { @MainActor in
            guard !self.isScrubbing else { return }
            let ms = self.vlcPlayer.time.value?.doubleValue ?? 0
            self.current = ms / 1000.0
            if self.duration <= 0, let dur = self.vlcPlayer.media?.length.value?.doubleValue, dur > 0 { self.duration = dur / 1000.0 }
            self.cueText = (self.subtitlesOn && self.hasExternalCues) ? SRTParser.cue(at: self.current, in: self.cues) : nil
            self.periodicSave()
        }
    }

    func play() {
        if media.isEngineSupported { player.playImmediately(atRate: Float(rate)) } 
        else { vlcPlayer.play(); if rate != 1.0 { vlcPlayer.rate = Float(rate) } }
        isPlaying = true
        let prog = duration > 0 ? (current / duration) : 0
        TraktService.shared.scrobble(item: media, progress: prog, action: .start)
    }

    func pause() {
        if media.isEngineSupported { player.pause() } else { vlcPlayer.pause() }
        isPlaying = false
        saveNow()
        let prog = duration > 0 ? (current / duration) : 0
        TraktService.shared.scrobble(item: media, progress: prog, action: .pause)
    }

    func togglePlay() { if isPlaying { pause() } else { play() }; scheduleAutoHide() }

    func seek(to target: Double) {
        let clamped = min(max(target, 0), duration > 0 ? max(duration - 0.5, 0) : target)
        if media.isEngineSupported { player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) } 
        else { vlcPlayer.time = VLCTime(int: Int32(clamped * 1000)) }
        current = clamped; scheduleAutoHide()
    }

    func skip(_ seconds: Double) { seek(to: current + seconds); flash(seconds >= 0 ? "+\(Int(seconds))s" : "\(Int(seconds))s") }

    func setRate(_ newRate: Double) {
        rate = newRate; UserDefaults.standard.set(newRate, forKey: "defaultRate")
        if isPlaying { if media.isEngineSupported { player.rate = Float(newRate) } else { vlcPlayer.rate = Float(newRate) } }
        flash(String(format: "%.2gx", newRate))
    }

    func setVolume(_ value: Double) {
        volumeLevel = min(max(value, 0), 1)
        if media.isEngineSupported { player.volume = Float(volumeLevel) } else { vlcPlayer.audio?.volume = Int32(volumeLevel * 100) }
        flash("Volume \(Int(volumeLevel * 100))%")
    }

    func toggleControls() { showControls.toggle(); if showControls { scheduleAutoHide() } }

    func scheduleAutoHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        let work = DispatchWorkItem { [weak self] in guard let self, self.isPlaying, !self.isScrubbing else { return }; withAnimation(.easeOut(duration: 0.25)) { self.showControls = false } }
        hideTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    func flash(_ text: String) {
        flashText = text; flashTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flashText = nil }
        flashTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
    
    private func loadSidecarSubtitles(for mediaURL: URL) {
        let srt = mediaURL.deletingPathExtension().appendingPathExtension("srt")
        guard FileManager.default.fileExists(atPath: srt.path) else { return }
        loadSubtitleFile(srt, copySidecar: false)
    }

    func loadSubtitleFile(_ url: URL, copySidecar: Bool = true) {
        let secured = url.startAccessingSecurityScopedResource(); defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let parsed = SRTParser.parse(text)
        guard !parsed.isEmpty else { flash("Couldn't read subtitles"); return }
        cues = parsed; hasExternalCues = true; subtitlesOn = true; flash("Subtitles loaded")
        if copySidecar { let dest = store.url(for: media).deletingPathExtension().appendingPathExtension("srt"); try? data.write(to: dest, options: .atomic) }
    }

    private func loadSelectionGroups(for item: AVPlayerItem) {
        let asset = item.asset
        Task { [weak self] in
            let chars = (try? await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)) ?? []
            let audio = chars.contains(.audible) ? try? await asset.loadMediaSelectionGroup(for: .audible) : nil
            let legible = chars.contains(.legible) ? try? await asset.loadMediaSelectionGroup(for: .legible) : nil
            guard let self else { return }
            self.audioGroup = audio; self.legibleGroup = legible
            self.audioOptions = audio?.options ?? []; self.legibleOptions = legible?.options ?? []
        }
    }

    func selectAudio(_ option: AVMediaSelectionOption) { guard let group = audioGroup else { return }; player.currentItem?.select(option, in: group); flash(option.displayName) }
    func selectLegible(_ option: AVMediaSelectionOption?) { guard let group = legibleGroup else { return }; player.currentItem?.select(option, in: group); if let option { flash(option.displayName) } }

    func togglePiP() {
        guard media.isEngineSupported else { flash("PiP unavailable for this format"); return }
        if pip == nil, AVPictureInPictureController.isPictureInPictureSupported(), let layer = layerHolder.playerLayer { pip = AVPictureInPictureController(playerLayer: layer) }
        guard let pip else { flash("PiP unavailable"); return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    private func periodicSave() { guard Date().timeIntervalSince(lastSave) > 4 else { return }; saveNow() }
    private func saveNow() { guard current > 0 || duration > 0 else { return }; lastSave = Date(); store.updateProgress(id: media.id, position: current, duration: duration) }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PlayerVM
    @State private var scrubValue: Double = 0
    @State private var showSubImporter = false
    @State private var dragMode: DragMode = .none
    @State private var dragStartValue: Double = 0
    @State private var seekTarget: Double = 0
    private enum DragMode { case none, seek, volume, brightness }

    init(item: MediaItem, store: LibraryStore) { _vm = StateObject(wrappedValue: PlayerVM(media: item, store: store)) }

    private var subtitleTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        for ext in ["srt", "vtt"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        return types
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if vm.media.isEngineSupported { PlayerLayerView(player: vm.player, holder: vm.layerHolder, gravity: vm.fillScreen ? .resizeAspectFill : .resizeAspect).ignoresSafeArea() } 
                else { VLCPlayerLayerView(player: vm.vlcPlayer).ignoresSafeArea() }
                subtitleOverlay
                if let flash = vm.flashText { OSDBadge(text: flash) }
                if vm.showControls { controls.transition(.opacity) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { point in if point.x < geo.size.width / 2 { vm.skip(-10) } else { vm.skip(10) } }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { vm.toggleControls() } }
            .gesture(panGesture(geo: geo))
        }
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear { vm.start(); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { vm.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .alert("Playback Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) { Button("OK") { dismiss() } } message: { Text(vm.errorMessage ?? "") }
        .fileImporter(isPresented: $showSubImporter, allowedContentTypes: subtitleTypes, allowsMultipleSelection: false) { result in if case .success(let urls) = result, let url = urls.first { vm.loadSubtitleFile(url) } }
        .preferredColorScheme(.dark)
    }

    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            if vm.subtitlesOn, let cue = vm.cueText {
                Text(cue).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 24)
            }
        }.padding(.bottom, vm.showControls ? 140 : 44).animation(.easeInOut(duration: 0.2), value: vm.showControls).allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 0) { topBar; Spacer(); centerButtons; Spacer(); bottomBar }
        .background(
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 130); Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 190)
            }.ignoresSafeArea().allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 40, height: 40) }
            Text(vm.media.title).font(.headline).lineLimit(1)
            Spacer()
            RoutePickerView().frame(width: 40, height: 40)
            Button { vm.togglePiP() } label: { Image(systemName: "pip.enter").font(.title3).frame(width: 40, height: 40) }
            trackMenu
        }.foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 6)
    }

    private var trackMenu: some View {
        Menu {
            if !vm.audioOptions.isEmpty { Section("Audio") { ForEach(vm.audioOptions, id: \.self) { o in Button(o.displayName) { vm.selectAudio(o) } } } }
            Section("Subtitles") {
                Button("Off") { vm.selectLegible(nil); vm.subtitlesOn = false }
                ForEach(vm.legibleOptions, id: \.self) { o in Button(o.displayName) { vm.selectLegible(o); vm.subtitlesOn = true } }
                Button("Load .srt file…") { showSubImporter = true }
                if vm.hasExternalCues { Toggle("External subtitles", isOn: $vm.subtitlesOn) }
            }
        } label: { Image(systemName: "captions.bubble").font(.title3).frame(width: 40, height: 40) }
    }

    private var centerButtons: some View {
        HStack(spacing: 58) {
            Button { vm.skip(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
            Button { vm.togglePlay() } label: { Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 56)).frame(width: 84, height: 84) }
            Button { vm.skip(10) } label: { Image(systemName: "goforward.10").font(.system(size: 34)) }
        }.foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(formatTime(vm.isScrubbing ? scrubValue : vm.current)).monospacedDigit()
                Slider(value: Binding(get: { vm.isScrubbing ? scrubValue : vm.current }, set: { scrubValue = $0 }), in: 0...max(vm.duration, 1),
                       onEditingChanged: { e in if e { scrubValue = vm.current; vm.isScrubbing = true } else { vm.isScrubbing = false; vm.seek(to: scrubValue) } }).tint(.purple)
                Text(formatTime(vm.duration)).monospacedDigit()
            }.font(.footnote).foregroundStyle(.white)

            HStack(spacing: 26) {
                Menu { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button(String(format: "%.2gx", r)) { vm.setRate(r) } } } label: { Label(String(format: "%.2gx", vm.rate), systemImage: "speedometer") }
                Button { vm.fillScreen.toggle() } label: { Image(systemName: vm.fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                Spacer()
            }.font(.subheadline).foregroundStyle(.white)
         }.padding(.horizontal, 16).padding(.bottom, 14)
    }

    private func panGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                if dragMode == .none {
                    if abs(value.translation.width) > abs(value.translation.height) { dragMode = .seek; dragStartValue = vm.current; seekTarget = vm.current } 
                    else if value.startLocation.x < geo.size.width / 2 { dragMode = .brightness; dragStartValue = Double(UIScreen.main.brightness) } 
                    else { dragMode = .volume; dragStartValue = vm.volumeLevel }
                }
                switch dragMode {
                case .seek:
                    let span = max(120, vm.duration * 0.3)
                    let delta = Double(value.translation.width / geo.size.width) * span
                    seekTarget = min(max(dragStartValue + delta, 0), max(vm.duration - 1, 0))
                    vm.flash("\(formatTime(seekTarget))  (\(delta >= 0 ? "+" : "-")\(formatTime(abs(delta))))")
                case .volume: vm.setVolume(dragStartValue - Double(value.translation.height / 300))
                case .brightness:
                    let level = min(max(dragStartValue - Double(value.translation.height / 300), 0), 1)
                    UIScreen.main.brightness = CGFloat(level); vm.flash("Brightness \(Int(level * 100))%")
                case .none: break
                }
            }
            .onEnded { _ in if dragMode == .seek { vm.seek(to: seekTarget) }; dragMode = .none }
    }
}

struct OSDBadge: View {
    let text: String
    var body: some View { Text(text).font(.headline.monospacedDigit()).padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white) }
}

// ============================================================
// LibraryView.swift
// ============================================================

enum LibrarySort: String, CaseIterable, Identifiable { case recent = "Recently Added", title = "Title", lastPlayed = "Last Played"; var id: String { rawValue } }

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var sort: LibrarySort = .recent
    
    @State private var playing: MediaItem?
    @State private var detailedItem: MediaItem? // Sheet state
    
    @State private var renaming: MediaItem?
    @State private var renameText = ""

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video]
        for ext in ["mkv", "webm", "ts", "m2ts", "flv", "wmv", "srt", "vtt", "flac", "ogg", "opus"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        return types
    }()

    var body: some View {
        NavigationStack {
            Group { if store.items.isEmpty { emptyState } else { libraryList } }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("Mina Anii")
            .searchable(text: $searchText, prompt: "Search your library")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    sortMenu; Button { showImporter = true } label: { Image(systemName: "plus") }; Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { r in if case .success(let urls) = r { Task { await store.importFiles(urls) } } }
        .fullScreenCover(item: $playing) { item in PlayerScreen(item: item, store: store) }
        .sheet(item: $detailedItem) { item in MediaDetailView(item: item, playingItem: $playing) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText); Button("Save") { if let item = renaming { store.rename(item, to: renameText) }; renaming = nil }; Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await store.rescan() }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await store.rescan() } } }
    }

    private var libraryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if searchText.isEmpty && !continueItems.isEmpty { sectionHeader("Continue Watching"); continueRow }
                sectionHeader(searchText.isEmpty ? "Library" : "Results")
                grid
            }.padding(.horizontal).padding(.top, 6).padding(.bottom, 32)
        }
    }

    private func sectionHeader(_ text: String) -> some View { Text(text).font(.title3.weight(.semibold)).foregroundStyle(.white) }

    private var continueRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(continueItems) { item in
                    Button { detailedItem = item } label: { ContinueCard(item: item, thumbURL: store.thumbURL(for: item)) }
                    .buttonStyle(.plain).contextMenu { contextButtons(for: item) }
                }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 16)], alignment: .leading, spacing: 22) {
            ForEach(filteredItems) { item in
                Button { detailedItem = item } label: { MediaCard(item: item, thumbURL: store.thumbURL(for: item)) }
                .buttonStyle(.plain).contextMenu { contextButtons(for: item) }
            }
        }
    }

    @ViewBuilder
    private func contextButtons(for item: MediaItem) -> some View {
        Button { playing = item } label: { Label("Play", systemImage: "play.fill") }
        Button { store.resetProgress(item); playing = item } label: { Label("Play from Beginning", systemImage: "gobackward") }
        Button { renameText = item.title; renaming = item } label: { Label("Rename", systemImage: "pencil") }
        if item.isWatched { Button { store.resetProgress(item) } label: { Label("Mark as Unwatched", systemImage: "eye.slash") } }
        else if item.duration > 0 { Button { store.markWatched(item) } label: { Label("Mark as Watched", systemImage: "eye") } }
        Button(role: .destructive) { store.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private var sortMenu: some View { Menu { Picker("Sort", selection: $sort) { ForEach(LibrarySort.allCases) { s in Text(s.rawValue).tag(s) } } } label: { Image(systemName: "arrow.up.arrow.down") } }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack").font(.system(size: 64)).foregroundStyle(.purple)
            Text("Your library is empty").font(.title2.weight(.semibold))
            Text("Import videos with the + button, share files to Mina Anii from any app, or drop them into On My iPad › Mina Anii using the Files app.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { showImporter = true } label: { Label("Import Media", systemImage: "plus").padding(.horizontal, 8) }.buttonStyle(.borderedProminent)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var continueItems: [MediaItem] { store.items.filter { $0.lastPosition > 20 && $0.duration > 0 && !$0.isWatched }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) } }
    private var filteredItems: [MediaItem] {
        var result = store.items
        if !searchText.isEmpty { result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.fileName.localizedCaseInsensitiveContains(searchText) } }
        switch sort {
        case .recent: result.sort { $0.dateAdded > $1.dateAdded }
        case .title: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .lastPlayed: result.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
        return result
    }
}

// MARK: - Cards

struct MediaCard: View {
    let item: MediaItem
    let thumbURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit).overlay(ThumbImage(url: thumbURL, isAudio: item.isAudio, metadata: item.metadata)).clipped()
                if item.progress > 0.01 && !item.isWatched {
                    GeometryReader { geo in Rectangle().fill(Color.purple).frame(width: geo.size.width * item.progress, height: 4).frame(maxHeight: .infinity, alignment: .bottom) }
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.duration > 0 { Text(formatTime(item.duration)).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.65), in: Capsule()).padding(6) }
            }
            .overlay(alignment: .topLeading) {
                if !item.isEngineSupported { Text(item.fileExtension.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 6).padding(.vertical, 3).background(.orange.opacity(0.9), in: Capsule()).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.metadata?.title ?? item.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.white)

            if let isTV = item.metadata?.isTVShow, isTV, let s = item.metadata?.season, let e = item.metadata?.episode {
                Text("Season \(s) • Episode \(e)").font(.caption2.weight(.bold)).foregroundStyle(.purple)
            }

            if let overview = item.metadata?.overview, !overview.isEmpty { Text(overview).font(.caption2).lineLimit(2).foregroundStyle(.secondary) } 
            else { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var caption: String {
        if item.isWatched { return "Watched" }
        if item.progress > 0.01, item.duration > 0 { return "\(formatTime(max(item.duration - item.lastPosition, 0))) left" }
        return item.fileExtension.uppercased()
    }
}

struct ContinueCard: View {
    let item: MediaItem
    let thumbURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(width: 256, height: 144).overlay(ThumbImage(url: thumbURL, isAudio: item.isAudio, metadata: item.metadata)).clipped()
                    .overlay(Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.92)))
                Rectangle().fill(Color.white.opacity(0.25)).frame(height: 4)
                Rectangle().fill(Color.purple).frame(width: 256 * item.progress, height: 4)
            }.clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.metadata?.title ?? item.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.white)
            Text("\(formatTime(max(item.duration - item.lastPosition, 0))) left").font(.caption).foregroundStyle(.secondary)
        }.frame(width: 256)
    }
}

struct ThumbImage: View {
    let url: URL
    var isAudio: Bool = false
    var metadata: MediaMetadata? = nil
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.10)], startPoint: .top, endPoint: .bottom))
                
                if let posterURL = metadata?.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { ProgressView() }
                    }
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: isAudio ? "music.note" : "film").font(.system(size: 30)).foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: url) { if metadata?.posterURL == nil { image = await Self.load(url) } }
    }

    static func load(_ url: URL) async -> UIImage? {
        let path = url.path; return await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value
    }
}

// ============================================================
// MediaDetailView.swift
// ============================================================

struct MediaDetailView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @Binding var playingItem: MediaItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                
                ZStack(alignment: .bottomLeading) {
                    if let backdrop = item.metadata?.backdropURL {
                        AsyncImage(url: backdrop) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() }
                            else { Color(white: 0.12) }
                        }
                        .frame(height: 380).clipped().overlay(LinearGradient(colors: [.clear, Color(white: 0.06)], startPoint: .center, endPoint: .bottom))
                    } else {
                        Color(white: 0.12).frame(height: 380).overlay(LinearGradient(colors: [.clear, Color(white: 0.06)], startPoint: .center, endPoint: .bottom))
                    }
                    
                    HStack(alignment: .bottom, spacing: 20) {
                        if let poster = item.metadata?.posterURL {
                            AsyncImage(url: poster) { phase in
                                if let img = phase.image { img.resizable().scaledToFit() } else { Color(white: 0.2) }
                            }
                            .frame(width: 140, height: 210).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.metadata?.title ?? item.title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                            
                            if let isTV = item.metadata?.isTVShow, isTV, let s = item.metadata?.season, let e = item.metadata?.episode {
                                Text("Season \(s) • Episode \(e)").font(.headline).foregroundStyle(.purple)
                            }
                            
                            HStack(spacing: 14) {
                                if let year = item.metadata?.releaseYear, !year.isEmpty { Text(year) }
                                if let rating = item.metadata?.rating, rating > 0 { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow) }
                                Text(formatTime(item.duration))
                                Text(item.fileExtension.uppercased()).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            }.font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                            
                            if let genres = item.metadata?.genres, !genres.isEmpty {
                                Text(genres.joined(separator: " • ")).font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                        }.padding(.bottom, 10)
                    }.padding(.horizontal, 24).offset(y: 40)
                }
                
                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 16) {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { playingItem = item }
                        } label: {
                            let isResuming = item.progress > 0.01 && !item.isWatched
                            Label(isResuming ? "Resume" : "Play", systemImage: "play.fill")
                                .font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.purple).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(.top, 60)
                    
                    if let overview = item.metadata?.overview, !overview.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Synopsis").font(.title3.weight(.bold)).foregroundStyle(.white)
                            Text(overview).font(.body).lineSpacing(4).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    
                    if let cast = item.metadata?.cast, !cast.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Cast").font(.title3.weight(.bold)).foregroundStyle(.white)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(cast, id: \.self) { actor in
                                        Text(actor).font(.subheadline).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10).background(Color.white.opacity(0.1)).clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 40)
            }
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.6), .black.opacity(0.4)) }.padding()
        }
    }
}

// ============================================================
// SettingsView.swift
// ============================================================

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var trakt = TraktService.shared
    
    @AppStorage("autoResume") private var autoResume = true
    @AppStorage("defaultRate") private var defaultRate = 1.0
    @State private var storageText = "Calculating…"
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Toggle("Resume where I left off", isOn: $autoResume)
                    Picker("Default speed", selection: $defaultRate) { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Text(String(format: "%.2gx", r)).tag(r) } }
                }
                
                Section("Trakt.tv") {
                    if trakt.isAuthenticated {
                        LabeledContent("Status", value: "Connected")
                        Button("Disconnect Trakt", role: .destructive) { trakt.logout() }
                    } else if trakt.isAuthenticating {
                        VStack(alignment: .center, spacing: 12) {
                            ProgressView()
                            Text("Go to \(trakt.authVerificationURL ?? "trakt.tv/activate") on your phone").font(.subheadline).multilineTextAlignment(.center)
                            if let code = trakt.authUserCode { Text(code).font(.largeTitle.monospaced().bold()) }
                            Text("Waiting for approval...").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                        Button("Cancel") { trakt.logout() }
                    } else {
                        Button("Connect to Trakt") { Task { await trakt.startDeviceAuthentication() } }
                    }
                }
                
                Section("Library") {
                    LabeledContent("Storage used", value: storageText)
                    Button("Rescan for new files") { Task { await store.rescan(); storageText = store.storageString() } }
                    Button("Clear watch history") { store.clearProgress() }
                    Button("Delete all media", role: .destructive) { confirmWipe = true }
                }
                
                Section("Adding media") {
                    Text("Use the + button in the library, share any video to Mina Anii from another app, or drop files into On My iPad › Mina Anii with the Files app, and they're picked up automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                
                Section("About") {
                    LabeledContent("App", value: "Mina Anii")
                    LabeledContent("Developer", value: "Polao")
                    LabeledContent("Version", value: "1.0 (1)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete all imported media? This can't be undone.", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { store.deleteAll(); storageText = store.storageString() }
            }
            .task { storageText = store.storageString() }
        }
    }
}
