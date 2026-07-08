import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var trakt = TraktService.shared

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
