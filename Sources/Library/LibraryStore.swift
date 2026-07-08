import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor // FIXED: Added the @ symbol here
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    private let fm = FileManager.default
    let documentsURL: URL; let mediaDir: URL; let thumbsDir: URL; private let indexURL: URL

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
        guard let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded
    }
    func save() { guard let data = try? JSONEncoder().encode(items) else { return }; try? data.write(to: indexURL, options: .atomic) }

    func url(for item: MediaItem) -> URL { mediaDir.appendingPathComponent(item.fileName) }
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
        await ingest(fileURL: dest); save()
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
                    try? fm.removeItem(at: dest); try? fm.moveItem(at: f, to: dest)
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
                await ingest(fileURL: f); changed = true
            }
        }
        let before = items.count; items.removeAll { !fm.fileExists(atPath: url(for: $0).path) }
        if changed || items.count != before { save() }
    }

    func updateProgress(id: UUID, position: Double, duration: Double) { guard let i = items.firstIndex(where: { $0.id == id }) else { return }; items[i].lastPosition = max(0, position); if duration > 0, duration.isFinite { items[i].duration = duration }; items[i].lastPlayed = Date(); save() }
    func resetProgress(_ item: MediaItem) { guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }; items[i].lastPosition = 0; save() }
    func markWatched(_ item: MediaItem) { guard let i = items.firstIndex(where: { $0.id == item.id }), items[i].duration > 0 else { return }; items[i].lastPosition = items[i].duration; items[i].lastPlayed = Date(); save() }
    func rename(_ item: MediaItem, to newTitle: String) { let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty, let i = items.firstIndex(where: { $0.id == item.id }) else { return }; items[i].title = trimmed; save() }
    func delete(_ item: MediaItem) { try? fm.removeItem(at: url(for: item)); try? fm.removeItem(at: thumbURL(for: item)); let sidecar = url(for: item).deletingPathExtension().appendingPathExtension("srt"); try? fm.removeItem(at: sidecar); items.removeAll { $0.id == item.id }; save() }
    func clearProgress() { for i in items.indices { items[i].lastPosition = 0; items[i].lastPlayed = nil }; save() }
    func deleteAll() { for item in items { try? fm.removeItem(at: url(for: item)); try? fm.removeItem(at: thumbURL(for: item)) }; items.removeAll(); save() }
    func storageString() -> String { var total: Int64 = 0; if let enumerator = fm.enumerator(at: mediaDir, includingPropertiesForKeys: [.fileSizeKey]) { for case let f as URL in enumerator { if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) } } }; return ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }

    static func prettyTitle(from raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        if !s.contains(" ") { s = s.replacingOccurrences(of: ".", with: " ") }
        let lower = s.lowercased()
        let markers = ["1080p", "720p", "2160p", "480p", "4k", "x264", "x265", "h264", "h265", "hevc", "web-dl", "webdl", "webrip", "bluray", "brrip", "bdrip", "hdrip", "hdtv", "dvdrip", "remux", "10bit", "yify", "rarbg", "aac"]
        var cut = s.count
        for m in markers { if let r = lower.range(of: m) { cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound)) } }
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
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: assetURL)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 720, height: 720); generator.requestedTimeToleranceBefore = .positiveInfinity; generator.requestedTimeToleranceAfter = .positiveInfinity
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
            let image = UIImage(cgImage: cg); guard let data = image.jpegData(compressionQuality: 0.75) else { return }; try? data.write(to: dest, options: .atomic)
        }.value
    }
}

func formatTime(_ t: Double) -> String { guard t.isFinite, t >= 0 else { return "0:00" }; let total = Int(t.rounded()); let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60; return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s) }
