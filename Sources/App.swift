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
// Trakt Models & Service
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
    private var refreshToken: String?
    private var expiresAt: Date?
    @Published var isAuthenticating = false

    var isAuthenticated: Bool { !accessToken.isEmpty }
    
    var authorizationURL: URL? {
        guard !clientID.isEmpty else { return nil }
        let urlString = "https://trakt.tv/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=\(redirectURI)"
        return URL(string: urlString)
    }

    private init() {
        accessToken = Keychain.get(Key.access) ?? ""
        refreshToken = Keychain.get(Key.refresh)
        if let raw = Keychain.get(Key.expiry), let ts = Double(raw) { expiresAt = Date(timeIntervalSince1970: ts) }
    }

    private func persistTokens(_ token: TraktTokenResponse) {
        accessToken = token.access_token; Keychain.set(token.access_token, for: Key.access)
        if let refresh = token.refresh_token { refreshToken = refresh; Keychain.set(refresh, for: Key.refresh) }
        if let expiresIn = token.expires_in {
            let base = token.created_at.map(Double.init) ?? Date().timeIntervalSince1970
            let expiry = base + Double(expiresIn)
            expiresAt = Date(timeIntervalSince1970: expiry)
            Keychain.set(String(expiry), for: Key.expiry)
        }
    }

    func handleAuthRedirect(url: URL) async {
        guard url.scheme == "minaanii", url.host == "oauth", url.path == "/trakt" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            isAuthenticating = false; return
        }
        
        isAuthenticating = true
        guard let tokenURL = URL(string: "https://api.trakt.tv/oauth/token") else { return }
        var request = URLRequest(url: tokenURL); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["code": code, "client_id": clientID, "client_secret": clientSecret, "redirect_uri": redirectURI, "grant_type": "authorization_code"]
        request.httpBody = try? JSONEncoder().encode(body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let tokenData = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) { persistTokens(tokenData) }
            }
        } catch { print("Trakt Token Exchange Error: \(error)") }
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
        if http.statusCode == 200, let token = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) { persistTokens(token) } 
        else if http.statusCode == 401 { logout() }
    }

    func logout() {
        accessToken = ""; refreshToken = nil; expiresAt = nil
        Keychain.delete(Key.access); Keychain.delete(Key.refresh); Keychain.delete(Key.expiry); isAuthenticating = false
    }
    
    enum ScrobbleAction: String { case start = "start", pause = "pause", stop = "stop" }
    
    func scrobble(item: MediaItem, progress: Double, action: ScrobbleAction) {
        guard isAuthenticated, let metadata = item.metadata, metadata.tmdbID > 0 else { return }
        
        let url = URL(string: "https://api.trakt.tv/scrobble/\(action.rawValue)")!
        var request = URLRequest(url: url); request.httpMethod = "POST"
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
                if let httpResponse = response as? HTTPURLResponse { print("Trakt Scrobble (\(action.rawValue)) Status: \(httpResponse.statusCode)") }
            } catch { print("Trakt Scrobble Error: \(error)") }
        }
    }
}

