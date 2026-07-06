import Foundation
import SwiftUI

// MARK: - Trakt Models

struct TraktDeviceCodeResponse: Codable {
    let device_code: String
    let user_code: String
    let verification_url: String
    let expires_in: Int
    let interval: Int
}

struct TraktTokenResponse: Codable {
    let access_token: String
}

// MARK: - Trakt Service

@MainActor
final class TraktService: ObservableObject {
    static let shared = TraktService()
    
    private let clientID = "f0bf471d51d179c7ad8c96db05fe4e3b010e9e229be87f884c1d5ed8457520bc"
    private let clientSecret = "0f5e6adf584cd84a56e3707d2bf4b7cca7602c479e09edc421ce2c01de7fe06d"
    
    @AppStorage("traktAccessToken") var accessToken: String = ""
    
    @Published var isAuthenticating = false
    @Published var authUserCode: String?
    @Published var authVerificationURL: String?
    
    var isAuthenticated: Bool {
        !accessToken.isEmpty
    }
    
    private var authTask: Task<Void, Never>?
    
    // MARK: - Authentication (Device Flow)
    
    func startDeviceAuthentication() async {
        guard !clientID.isEmpty, clientID != "YOUR_TRAKT_CLIENT_ID" else {
            print("Trakt Error: Missing Client ID")
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
            
            // Start polling for the token
            pollForToken(deviceCode: response.device_code, interval: response.interval, expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
        } catch {
            print("Trakt Device Code Error: \(error)")
            isAuthenticating = false
        }
    }
    
    private func pollForToken(deviceCode: String, interval: Int, expiresAt: Date) {
        authTask?.cancel()
        authTask = Task {
            while Date() < expiresAt {
                if Task.isCancelled { break }
                
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                
                guard let url = URL(string: "https://api.trakt.tv/oauth/device/token") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let body: [String: String] = [
                    "code": deviceCode,
                    "client_id": clientID,
                    "client_secret": clientSecret
                ]
                request.httpBody = try? JSONEncoder().encode(body)
                
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    
                    if let tokenData = try? JSONDecoder().decode(TraktTokenResponse.self, from: data) {
                        self.accessToken = tokenData.access_token
                        self.isAuthenticating = false
                        self.authUserCode = nil
                        break
                    }
                }
            }
            self.isAuthenticating = false
        }
    }
    
    func logout() {
        authTask?.cancel()
        accessToken = ""
        isAuthenticating = false
    }
    
    // MARK: - Scrobbling
    
    enum ScrobbleAction: String {
        case start = "start"
        case pause = "pause"
        case stop = "stop"
    }
    
    func scrobble(item: MediaItem, progress: Double, action: ScrobbleAction) {
        guard isAuthenticated, let metadata = item.metadata, metadata.tmdbID > 0 else { return }
        
        let url = URL(string: "https://api.trakt.tv/scrobble/\(action.rawValue)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        var payload: [String: Any] = [
            "progress": progress * 100,
            "app_version": "1.0",
            "app_date": "2024-01-01"
        ]
        
        if metadata.isTVShow {
            payload["episode"] = [
                "season": metadata.season ?? 1,
                "number": metadata.episode ?? 1
            ]
            payload["show"] = [
                "ids": ["tmdb": metadata.tmdbID]
            ]
        } else {
            payload["movie"] = [
                "title": metadata.title,
                "year": Int(metadata.releaseYear) ?? 0,
                "ids": ["tmdb": metadata.tmdbID]
            ]
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        Task.detached {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    print("Trakt Scrobble (\(action.rawValue)) Status: \(httpResponse.statusCode)")
                }
            } catch {
                print("Trakt Scrobble Error: \(error)")
            }
        }
    }
}
