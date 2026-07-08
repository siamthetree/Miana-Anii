
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var folders: [WatchedFolder] = []
    @Published private(set) var isScanning = false

    private let fm = FileManager.default
    let documentsURL: URL
    let mediaDir: URL
    let thumbsDir: URL
    private let indexURL: URL
    private let foldersURL: URL

    /// Resolved, access-started URL for each watched folder. Missing key means
    /// the folder could not be reached this launch.
    private var folderURLs: [UUID: URL] = [:]
    private let watcher = FolderWatcher()
    private var debouncedScan: Task<Void, Never>?

    init() {
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mediaDir = documentsURL.appendingPathComponent("Media", isDirectory: true)
        thumbsDir = documentsURL.appendingPathComponent("Thumbnails", isDirectory: true)
        indexURL = documentsURL.appendingPathComponent("library.json")
        foldersURL = documentsURL.appendingPathComponent("folders.json")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        load()
        loadFolders()
        activateFolders()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func loadFolders() {
        guard let data = try? Data(contentsOf: foldersURL),
              let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) else { return }
        folders = decoded
    }

    private func saveFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }

    // MARK: - Paths

    func url(for item: MediaItem) -> URL {
        if let folderID = item.folderID, let relative = item.relativePath, let root = folderURLs[folderID] {
            return root.appendingPathComponent(relative)
        }
        return mediaDir.appendingPathComponent(item.fileName)
    }

    func thumbURL(for item: MediaItem) -> URL {
        thumbsDir.appendingPathComponent(item.id.uuidString + ".jpg")
    }

    /// True when the item's watched folder is unreachable right now.
    func isOffline(_ item: MediaItem) -> Bool {
        guard let folderID = item.folderID else { return false }
        return folderURLs[folderID] == nil
    }

    func itemCount(in folder: WatchedFolder) -> Int {
        items.filter { $0.folderID == folder.id }.count
    }

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

    // MARK: - Watched folders

    /// Resolves every stored bookmark, holds its security scope open, and
    /// starts a kqueue watcher on it. Called once at launch.
    private func activateFolders() {
        for folder in folders { activate(folder) }
    }

    private func activate(_ folder: WatchedFolder) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }

        folderURLs[folder.id] = url

        if stale, let refreshed = try? url.bookmarkData(),
           let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark = refreshed
            saveFolders()
        }

        watcher.watch(folderID: folder.id, directories: directories(under: url)) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.scheduleFolderScan() }
        }
    }

    func addFolder(_ pickedURL: URL) async {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? pickedURL.bookmarkData() else { return }
        let alreadyWatching = folders.contains { folder in
            folderURLs[folder.id]?.standardizedFileURL == pickedURL.standardizedFileURL
        }
        guard !alreadyWatching else { return }

        let folder = WatchedFolder(name: pickedURL.lastPathComponent, bookmark: bookmark)
        folders.append(folder)
        saveFolders()
        activate(folder)
        await scanFolders()
    }

    /// Forgets the folder and drops its library entries. Never touches the
    /// files on disk.
    func removeFolder(_ folder: WatchedFolder) {
        watcher.stop(folderID: folder.id)
        folderURLs[folder.id]?.stopAccessingSecurityScopedResource()
        folderURLs[folder.id] = nil

        for item in items where item.folderID == folder.id {
            try? fm.removeItem(at: thumbURL(for: item))
        }
        items.removeAll { $0.folderID == folder.id }
        folders.removeAll { $0.id == folder.id }
        saveFolders()
        save()
    }

    /// Coalesces a burst of filesystem events into one scan, and gives a file
    /// that is still being copied a couple of seconds to finish.
    private func scheduleFolderScan() {
        debouncedScan?.cancel()
        debouncedScan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.scanFolders()
        }
    }

    func scanFolders() async {
        guard !folders.isEmpty, !isScanning else { return }
        isScanning = true
        var sawUnsettledFile = false

        for folder in folders {
            guard let root = folderURLs[folder.id] else { continue }
            for file in mediaFiles(under: root) {
                let relative = Self.relativePath(of: file, from: root)
                if items.contains(where: { $0.folderID == folder.id && $0.relativePath == relative }) { continue }

                // A file whose bytes landed a moment ago is probably still copying.
                if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   Date().timeIntervalSince(modified) < 3 {
                    sawUnsettledFile = true
                    continue
                }
                await ingest(fileURL: file, folderID: folder.id, relativePath: relative)
            }
            watcher.watch(folderID: folder.id, directories: directories(under: root)) { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.scheduleFolderScan() }
            }
        }

        pruneMissing()
        save()
        isScanning = false
        if sawUnsettledFile { scheduleFolderScan() }
    }

    private func mediaFiles(under root: URL) -> [URL] {
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard MediaKinds.media.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
        }
        return found
    }

    private func directories(under root: URL) -> [URL] {
        var result = [root]
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        for case let url as URL in enumerator {
            guard result.count < FolderWatcher.maxDirectories else { break }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { result.append(url) }
        }
        return result
    }

    static func relativePath(of file: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Importing copies

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
            let from = src, to = dest
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: from, to: to) }.value
        } catch { return }

        if src.path.contains("/Inbox/") { try? fm.removeItem(at: src) }
        await ingest(fileURL: dest)
        save()
    }

    private func ingest(fileURL: URL, folderID: UUID? = nil, relativePath: String? = nil) async {
        let rawTitle = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let prettyTitle = Self.prettyTitle(from: rawTitle)

        var item = MediaItem(title: prettyTitle, fileName: fileURL.lastPathComponent)
        item.folderID = folderID
        item.relativePath = relativePath

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

    // MARK: - Scanning

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
                guard MediaKinds.media.contains(f.pathExtension.lowercased()) else { continue }
                guard !items.contains(where: { $0.folderID == nil && $0.fileName == f.lastPathComponent }) else { continue }
                await ingest(fileURL: f)
                changed = true
            }
        }

        await scanFolders()

        let before = items.count
        pruneMissing()
        if changed || items.count != before { save() }
    }

    /// Drops items whose file is gone. An item belonging to an unreachable
    /// folder is left alone, because "unreachable" is not "deleted".
    private func pruneMissing() {
        items.removeAll { item in
            if item.folderID != nil && isOffline(item) { return false }
            return !fm.fileExists(atPath: url(for: item).path)
        }
    }

    /// Re-queries TMDB for every item and rewrites its metadata in place.
    func refreshMetadata() async {
        let snapshot = items
        for item in snapshot {
            let raw = (item.fileName as NSString).deletingPathExtension
            let clean = Self.prettyTitle(from: raw)
            guard let meta = await MetadataService.fetchMetadata(for: item.fileName, cleanTitle: clean) else { continue }
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            items[index].metadata = meta
        }
        save()
    }

    // MARK: - Mutations

    func updateProgress(id: UUID, position: Double, duration: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastPosition = max(0, position)
        if duration > 0, duration.isFinite { items[i].duration = duration }
        items[i].lastPlayed = Date()
        save()
    }

    func resetProgress(_ item: MediaItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].lastPosition = 0; save()
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
        items[i].title = trimmed; save()
    }

    /// Deletes the file, whether it is a copy in Media or the original inside a
    /// watched folder. Removing it from the library alone would not stick: the
    /// next scan would find the file and add it straight back.
    func delete(_ item: MediaItem) {
        if !isOffline(item) {
            let target = url(for: item)
            try? fm.removeItem(at: target)
            try? fm.removeItem(at: target.deletingPathExtension().appendingPathExtension("srt"))
        }
        try? fm.removeItem(at: thumbURL(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearProgress() {
        for i in items.indices { items[i].lastPosition = 0; items[i].lastPlayed = nil }
        save()
    }

    /// Wipes imported copies and forgets every watched folder. Files inside a
    /// watched folder are left on disk.
    func deleteAll() {
        for item in items {
            if item.folderID == nil { try? fm.removeItem(at: url(for: item)) }
            try? fm.removeItem(at: thumbURL(for: item))
        }
        watcher.stopAll()
        for url in folderURLs.values { url.stopAccessingSecurityScopedResource() }
        folderURLs.removeAll()
        folders.removeAll()
        items.removeAll()
        saveFolders()
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

    // MARK: - Helpers

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
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
