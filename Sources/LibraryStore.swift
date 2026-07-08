import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published var items: [MediaItem] = []

    private let saveFilename = "library.json"

    init() {
        load()
    }

    func importFile(_ externalURL: URL) async {
        do {
            let importedURL = try copyToDocumentsIfNeeded(externalURL)
            let title = importedURL.deletingPathExtension().lastPathComponent

            // Avoid duplicates
            if items.contains(where: { $0.fileURL == importedURL }) { return }

            var item = MediaItem(title: title, fileURL: importedURL)

            // Optional metadata lookup (safe fallback if it fails)
            if let metadata = await MetadataService.fetchMetadata(
                for: importedURL.lastPathComponent,
                cleanTitle: title
            ) {
                item.metadata = metadata
            }

            items.insert(item, at: 0)
            save()
        } catch {
            print("Import failed: \(error)")
        }
    }

    func remove(at offsets: IndexSet) {
        let removed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)

        // Optional: delete local file
        for item in removed {
            try? FileManager.default.removeItem(at: item.fileURL)
        }

        save()
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: saveURL(), options: .atomic)
        } catch {
            print("Save failed: \(error)")
        }
    }

    private func load() {
        do {
            let url = saveURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([MediaItem].self, from: data)
        } catch {
            print("Load failed: \(error)")
            items = []
        }
    }

    private func saveURL() -> URL {
        documentsDirectory().appendingPathComponent(saveFilename)
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func copyToDocumentsIfNeeded(_ sourceURL: URL) throws -> URL {
        let dest = documentsDirectory().appendingPathComponent(sourceURL.lastPathComponent)

        // Security-scoped access for Files app URLs
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }

        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }
}
