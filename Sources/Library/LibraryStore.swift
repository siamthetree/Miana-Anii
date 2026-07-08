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
            let filename = importedURL.deletingPathExtension().lastPathComponent

            if items.contains(where: { $0.fileURL == importedURL }) { return }

            var cleanTitle = filename.replacingOccurrences(of: ".", with: " ")
                                     .replacingOccurrences(of: "_", with: " ")
            
            let pattern = "(1080p|720p|4k|2160p|x264|x265|blu-?ray|web-?dl|\\[.*\\]|\\(.*\\))"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: cleanTitle.utf16.count)
                cleanTitle = regex.stringByReplacingMatches(in: cleanTitle, options: [], range: range, withTemplate: "")
            }
            cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)

            var item = MediaItem(title: filename, fileURL: importedURL)

            if let metadata = await MetadataService.fetchMetadata(
                for: importedURL.lastPathComponent,
                cleanTitle: cleanTitle
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
        let started = sourceURL.startAccessingSecurityScopedResource()
        defer { if started { sourceURL.stopAccessingSecurityScopedResource() } }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }
}
