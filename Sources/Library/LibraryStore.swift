// ==========================================================
//  BUG 7 + CONCURRENCY FIXES (Combined)
//
//  File:  Sources/Library/LibraryStore.swift
//  Replace the entire file.
// ==========================================================

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

    /// done and total while a metadata refresh runs, nil when idle.
    @Published private(set) var refreshProgress: (done: Int, total: Int)?

    /// The library, collapsed into movies and shows. Rebuilt once whenever items
    /// changes, not on every read.
    @Published private(set) var entries: [LibraryEntry] = []
    private var seriesIndex: [String: Series] = [:]

    func series(withID id: String) -> Series? { seriesIndex[id] }

    private let fm = FileManager.default
    let documentsURL: URL
    let mediaDir: URL
    let thumbsDir: URL
    let subsDir: URL
    private let indexURL: URL
    private let foldersURL: URL

    /// Resolved, access-started URL for each watched folder.
    private var folderURLs: [UUID: URL] = [:]
    private let watcher = FolderWatcher()
    private var debouncedScan: Task<Void, Never>?
    
    // MARK: - Concurrency Queue
    private var importQueue: [URL] = []
    private var isProcessingQueue = false

    init() {
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mediaDir = documentsURL.appendingPathComponent("Media", isDirectory: true)
        thumbsDir = documentsURL.appendingPathComponent("Thumbnails", isDirectory: true)
        subsDir = documentsURL.appendingPathComponent("Subtitles", isDirectory: true)
        indexURL = documentsURL.appendingPathComponent("library.json")
        foldersURL = documentsURL.appendingPathComponent("folders.json")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: subsDir, withIntermediateDirectories: true)
        load()
        loadFolders()
        activateFolders()
    }

    // MARK: - Sequential Import Queue
    
    func enqueueImport(url: URL) {
        importQueue.append(url)
        if !isProcessingQueue { processNextQueueItem() }
    }

    private func processNextQueueItem() {
        guard !importQueue.isEmpty else {
            isProcessingQueue = false
            save()
            return
        }
        isProcessingQueue = true
        let nextURL = importQueue.removeFirst()
        Task {
            await importFile(nextURL)
            processNextQueueItem()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded
        regroup()
    }

    func save() {
        regroup()
        guard let data = try? JSONEncoder().encode(items) else { return }
        let targetURL = indexURL
        
        // Push the disk-write off the main UI thread
        Task.detached(priority: .background) {
            try? data.write(to: targetURL, options: .atomic)
        }
    }

    private func regroup() {
        entries = items.groupedIntoEntries()
        seriesIndex = entries.reduce(into: [:]) { index, entry in
            if case .series(let show) = entry { index[show.id] = show }
        }
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

    func savedSubtitleURL(for item: MediaItem) -> URL {
        subsDir.appendingPathComponent(item.id.uuidString + ".srt")
    }

    func sidecarSubtitleURL(for item: MediaItem) -> URL {
        url(for: item).deletingPathExtension().appendingPathExtension("srt")
    }

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

    func removeFolder(_ folder: WatchedFolder) {
        watcher.stop(folderID: folder.id)
        folderURLs[folder.id]?.stopAccessingSecurityScopedResource()
        folderURLs[folder.id] = nil

        for item in items where item.folderID == folder.id {
            try? fm.removeItem(at: thumbURL(for: item))
            try? fm.removeItem(at: savedSubtitleURL(for: item))
        }
        items.removeAll { $0.folderID == folder.id }
        saveFolders()
        save()
    }

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

        if item.isEngineSupported {
            let asset = AVURLAsset(url: fileURL)
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { item.duration = d.seconds }
        }
        if item.duration <= 0 {
            let probeURL = fileURL
            item.duration = await Task.detached(priority: .utility) { VLCProbe.duration(of: probeURL) }.value
        }

        if !item.isAudio {
            let destination = thumbURL(for: item)
            if item.isEngineSupported {
                let seconds = item.duration > 0 ? max(1.0, item.duration * 0.12) : 3.0
                await Self.writeThumbnail(assetURL: fileURL, at: seconds, to: destination)
            } else {
                await VLCProbe.writeThumbnail(for: fileURL, position: 0.12, to: destination)
            }
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

    private func pruneMissing() {
        items.removeAll { item in
            if item.folderID != nil && isOffline(item) { return false }
            return !fm.fileExists(atPath: url(for: item).path)
        }
    }

    func refreshMetadata() async {
        guard refreshProgress == nil else { return }

        await TMDBCache.shared.clear()

        let snapshot = items
        guard !snapshot.isEmpty else { return }
        refreshProgress = (0, snapshot.count)
        defer { refreshProgress = nil }

        let concurrency = 4
        var next = 0
        var done = 0

        await withTaskGroup(of: (UUID, MediaMetadata?).self) { group in
            func enqueue() {
                guard next < snapshot.count else { return }
                let item = snapshot[next]
                next += 1

                let fileName = item.fileName
                let clean = Self.prettyTitle(from: (fileName as NSString).deletingPathExtension)
                let id = item.id
                group.addTask {
                    (id, await MetadataService.fetchMetadata(for: fileName, cleanTitle: clean))
                }
            }

            for _ in 0..<concurrency { enqueue() }

            while let (id, meta) = await group.next() {
                done += 1
                refreshProgress = (done, snapshot.count)
                if let meta, let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].metadata = meta
                }
                enqueue()
            }
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
        resetProgress([item])
    }

    func resetProgress(_ batch: [MediaItem]) {
        var touched = false
        for item in batch {
            guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
            items[i].lastPosition = 0
            touched = true
        }
        if touched { save() }
    }

    func markWatched(_ item: MediaItem) {
        markWatched([item])
    }

    func markWatched(_ batch: [MediaItem]) {
        let now = Date()
        var touched = false
        for item in batch {
            guard let i = items.firstIndex(where: { $0.id == item.id }), items[i].duration > 0 else { continue }
            items[i].lastPosition = items[i].duration
            items[i].lastPlayed = now
            touched = true
        }
        if touched { save() }
    }

    func rename(_ item: MediaItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].title = trimmed; save()
    }

    func delete(_ item: MediaItem) {
        let target = url(for: item)
        let thumb = thumbURL(for: item)
        let sub = savedSubtitleURL(for: item)
        let isExt = item.isExternal
        let offline = isOffline(item)

        items.removeAll { $0.id == item.id }
        save()

        // Hand the heavy unlinking to the file system in the background
        Task.detached(priority: .userInitiated) {
            let localFm = FileManager.default
            if !offline {
                try? localFm.removeItem(at: target)
                if !isExt {
                    try? localFm.removeItem(at: target.deletingPathExtension().appendingPathExtension("srt"))
                }
            }
            try? localFm.removeItem(at: thumb)
            try? localFm.removeItem(at: sub)
        }
    }

    func clearProgress() {
        for i in items.indices { items[i].lastPosition = 0; items[i].lastPlayed = nil }
        save()
    }

    func deleteAll() {
        for item in items {
            if item.folderID == nil { try? fm.removeItem(at: url(for: item)) }
            try? fm.removeItem(at: thumbURL(for: item))
            try? fm.removeItem(at: savedSubtitleURL(for: item))
        }
        watcher.stopAll()
        for url in folderURLs.values { url.stopAccessingSecurityScopedResource() }
        folderURLs.removeAll()
        folders.removeAll()
        items.removeAll()
        saveFolders()
        save()
    }

    // MARK: - Asynchronous Storage Calculator
    func storageString() -> String {
        return "Calculating…" 
    }

    func calculateStorageAsync() async -> String {
        let path = mediaDir
        let totalBytes = await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let localFm = FileManager.default
            if let enumerator = localFm.enumerator(at: path, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in enumerator {
                    if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
                }
            }
            return total
        }.value
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    // MARK: - Helpers

    // NOTE: Safely marked nonisolated to allow calling from background TaskGroup
    nonisolated static func prettyTitle(from raw: String) -> String {
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
