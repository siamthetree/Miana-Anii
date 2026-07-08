import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var trakt = TraktService.shared

    @AppStorage("autoResume") private var autoResume = true
    @AppStorage("defaultRate") private var defaultRate = 1.0
    @AppStorage("autoHideInterval") private var autoHideInterval = 10.0

    @State private var storageText = "Calculating…"
    @State private var confirmWipe = false
    @State private var refreshing = false
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Toggle("Resume where I left off", isOn: $autoResume)

                    Picker("Default speed", selection: $defaultRate) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text(String(format: "%.2gx", r)).tag(r)
                        }
                    }

                    Picker("Auto-hide controls", selection: $autoHideInterval) {
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                        Text("Never").tag(0.0)
                    }
                }

                Section {
                    if store.folders.isEmpty {
                        Text("No sources yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.folders) { folder in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                Text("\(store.itemCount(in: folder)) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { store.folders[$0] }
                            for folder in doomed { store.removeFolder(folder) }
                        }
                    }

                    Button { showFolderPicker = true } label: {
                        Label("Add Media Source", systemImage: "folder.badge.plus")
                    }

                    if store.isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning sources…").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Media Sources")
                } footer: {
                    Text("A media source is a folder the app keeps an eye on. Drop new media into it and the library picks it up on its own. Files stay where they are, nothing is copied. Swipe a source away to remove it, which leaves every file untouched.")
                }

                Section("Trakt.tv") {
                    if trakt.isAuthenticated {
                        LabeledContent("Status", value: "Connected")
                        Button("Disconnect Trakt", role: .destructive) { trakt.logout() }
                    } else if let authURL = trakt.authorizationURL {
                        Link("Connect to Trakt", destination: authURL)
                    }
                }

                Section("Library") {
                    LabeledContent("Storage used", value: storageText)
                    Button("Rescan for new files") {
                        Task { await store.rescan(); storageText = store.storageString() }
                    }
                    Button(refreshing ? "Refreshing…" : "Refresh metadata") {
                        refreshing = true
                        Task { await store.refreshMetadata(); refreshing = false }
                    }
                    .disabled(refreshing)
                    Button("Clear watch history") { store.clearProgress() }
                    Button("Delete all media", role: .destructive) { confirmWipe = true }
                }

                Section("Adding media") {
                    Text("Use the + button in the library, share any video to Mina Anii from another app, or drop files into On My iPad › Mina Anii with the Files app. For a folder you keep adding to, add it as a media source above.")
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
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { Task { await store.addFolder(url) } }
            }
            .confirmationDialog("Delete all imported media and remove every media source? Files inside a source folder are left alone.",
                                isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { store.deleteAll(); storageText = store.storageString() }
            }
            .task { storageText = store.storageString() }
        }
    }
}
