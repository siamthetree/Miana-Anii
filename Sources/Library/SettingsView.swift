import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var trakt = TraktService.shared
    
    // Saves the preferred skip interval to device memory (default is 15 seconds)
    @AppStorage("skipInterval") private var skipInterval: Int = 15

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Playback Settings
                Section("Playback") {
                    Picker("Skip Button Interval", selection: $skipInterval) {
                        Text("5 Seconds").tag(5)
                        Text("10 Seconds").tag(10)
                        Text("15 Seconds").tag(15)
                        Text("30 Seconds").tag(30)
                    }
                }
                
                // MARK: - Trakt Integration
                Section("Trakt Integration") {
                    if trakt.isAuthenticated {
                        Text("Connected to Trakt")
                            .foregroundStyle(.green)
                        Button("Log Out", role: .destructive) {
                            trakt.logout()
                        }
                    } else {
                        if let authURL = trakt.authorizationURL {
                            Link("Log in to Trakt", destination: authURL)
                        } else {
                            Text("Trakt configuration missing.")
                        }
                    }
                }
                
                // MARK: - About the App
                Section("About") {
                    HStack {
                        Text("App Name")
                        Spacer()
                        Text("Mina Anii")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Developer")
                        Spacer()
                        // Replace with your actual name or studio name!
                        Text("Your Name Here") 
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
