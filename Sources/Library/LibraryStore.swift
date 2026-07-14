// ==========================================================
//  FINAL STABILIZED: DISK WRITER + ASYNC STREAM OBSERVER
//
//  File:  Sources/Library/LibraryStore.swift
//  Replace the entire file.
// ==========================================================

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

actor DiskWriter {
    static let shared = DiskWriter()
    func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var folders: [WatchedFolder] = []
    @Published private(set) var isScanning = false
    @Published private(set) var unreachableFolders: Set<UUID> = []
    @Published private(set) var refreshProgress: (done: Int, total: Int)?

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

    private var folderURLs: [UUID: URL] = [:]
    private let watcher = FolderWatcher()
    
    // SWIFT 6 ARCHITECTURE: Track the AsyncStream tasks
    private var watcherTasks: [UUID: Task<Void, Never>] = [:]
    
    private var debouncedScan: Task<Void, Never>?
    private var scanRequested = false
    private var watchedDirectories: [UUID: [URL]] = [:]
    
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
    
    func importFiles(_ urls: [URL]) async { for url in urls { enqueueImport(url: url) } }
    func importFile(_ url: URL) async { enqueueImport(url: url) }
    func enqueueImport(url: URL) { importQueue.append(url); if !isProcessingQueue { processNextQueueItem() } }

    private func processNextQueueItem() {
        guard !importQueue.isEmpty else { isProcessingQueue = false; save(); return }
        isProcessingQueue = true
        let nextURL = importQueue.removeFirst()
        Task { await performImport(nextURL); processNextQueueItem() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded; regroup()
    }

    func save() {
        regroup()
        guard let data = try? JSONEncoder().encode(items) else { return }
        let targetURL = self.indexURL
        Task { await DiskWriter.shared.write(data, to: targetURL) }
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
        let targetURL = self.foldersURL
        Task { await DiskWriter.shared.write(data, to: targetURL) }
    }

    func url(for item: MediaItem) -> URL {
        if let folderID = item.folderID, let relative = item.relativePath, let root = folderURLs[folderID] { return root.appendingPathComponent(relative) }
        return mediaDir.appendingPathComponent(item.fileName)
    }
    func thumbURL(for item: MediaItem) -> URL { thumbsDir.appendingPathComponent(item.id.uuidString + ".jpg") }
    func savedSubtitleURL(for item: MediaItem) -> URL { subsDir.appendingPathComponent(item.id.uuidString + ".srt") }
    func sidecarSubtitleURL(for item: MediaItem) -> URL { url(for: item).deletingPathExtension().appendingPathExtension("srt") }
    func isOffline(_ item: MediaItem) -> Bool {
        guard let folderID = item.folderID else { return false }
        return folderURLs[folderID] == nil
    }
    func itemCount(in folder: WatchedFolder) -> Int { items.filter { $0.folderID == folder.id }.count }
    func isUnreachable(_ folder: WatchedFolder) -> Bool { unreachableFolders.contains(folder.id) }

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

    private func activateFolders() { for folder in folders { activate(folder) } }
    private func activate(_ folder: WatchedFolder) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        folderURLs[folder.id] = url
        if stale, let refreshed = try? url.bookmarkData(), let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmark = refreshed; saveFolders()
        }
        rewatchIfNeeded(folder.id, root: url)
    }

    private func rewatchIfNeeded(_ folderID: UUID, root: URL) {
        let current = directories(under: root)
        guard watchedDirectories[folderID] != current else { return }
        watchedDirectories[folderID] = current
        
        // SWIFT 6 ARCHITECTURE: Safely iterate the AsyncStream.
        // No cross-actor closures, no crashes.
        watcherTasks[folderID]?.cancel()
        watcherTasks[folderID] = Task { [weak self] in
            guard let self else { return }
            let stream = await self.watcher.watch(folderID: folderID, directories: current)
            for await _ in stream {
                guard !Task.isCancelled else { break }
                self.scheduleFolderScan()
            }
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
        folders.append(folder); saveFolders(); activate(folder); await scanFolders()
    }

    func removeFolder(_ folder: WatchedFolder) {
        watcherTasks[folder.id]?.cancel()
        watcherTasks[folder.id] = nil
        Task { await watcher.stop(folderID: folder.id) }
        
        watchedDirectories[folder.id] = nil
        folderURLs[folder.id]?.stopAccessingSecurityScopedResource()
        folderURLs[folder.id] = nil
        for item in items where item.folderID == folder.id {
            let t = thumbURL(for: item)
            let s = savedSubtitleURL(for: item)
            if fm.fileExists(atPath: t.path) { try? fm.removeItem(at: t) }
            if fm.fileExists(atPath: s.path) { try? fm.removeItem(at: s) }
        }
        items.removeAll { $0.folderID == folder.id }
        folders.removeAll { $0.id == folder.id }
        saveFolders(); save()
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
        guard !folders.isEmpty else { return }
        guard !isScanning else { scanRequested = true; return }
        isScanning = true
        defer { isScanning = false }
        repeat {
            scanRequested = false
            let unsettled = await scanFoldersOnce()
            pruneMissing(); save()
            if unsettled { scheduleFolderScan() }
        } while scanRequested
    }

    private func scanFoldersOnce() async -> Bool {
        var sawUnsettledFile = false
        for folder in folders {
            guard let root = folderURLs[folder.id] else { continue }
            let files = mediaFiles(under: root)
            if files.isEmpty && items.contains(where: { $0.folderID == folder.id }) { continue }
            for file in files {
                let relative = Self.relativePath(of: file, from: root)
                if items.contains(where: { $0.folderID == folder.id && $0.relativePath == relative }) { continue }
                if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   Date().timeIntervalSince(modified) < 3 { sawUnsettledFile = true; continue }
                await ingest(fileURL: file, folderID: folder.id, relativePath: relative)
            }
            rewatchIfNeeded(folder.id, root: root)
        }
        return sawUnsettledFile
    }

    private func mediaFiles(under root: URL) -> [URL] {
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL { if MediaKinds.media.contains(url.pathExtension.lowercased()) { found.append(url) } }
        return found
    }

    private func directories(under root: URL) -> [URL] {
        var result = [root]
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if result.count < FolderWatcher.maxDirectories, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { result.append(url) }
        }
        return result
    }

    static func relativePath(of file: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        return filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : file.lastPathComponent
    }

    private func performImport(_ src: URL) async {
        let secured = src.startAccessingSecurityScopedResource()
        defer { if secured { src.stopAccessingSecurityScopedResource() } }

        let ext = src.pathExtension.lowercased()
        if MediaKinds.subtitles.contains(ext) {
            let dest = mediaDir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dest); try? fm.copyItem(at: src, to: dest)
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

    func ingest(fileURL: URL, folderID: UUID? = nil, relativePath: String? = nil) async {
        let pretty = Self.prettyTitle(from: (fileURL.lastPathComponent as NSString).deletingPathExtension)
        var item = MediaItem(title: pretty, fileName: fileURL.lastPathComponent)
        item.folderID = folderID; item.relativePath = relativePath

        if let meta = await MetadataService.fetchMetadata(for: fileURL.lastPathComponent, cleanTitle: pretty) { item.metadata = meta }

        if item.isEngineSupported {
            let asset = AVURLAsset(url: fileURL)
            if let d = try? await asset.load(.duration), d.seconds > 0 { item.duration = d.seconds }
        }
        if item.duration <= 0 { item.duration = await VLCProbe.duration(of: fileURL) }

        if !item.isAudio {
            let dest = thumbURL(for: item)
            if item.isEngineSupported { await Self.writeThumbnail(assetURL: fileURL, at: max(1.0, item.duration * 0.12), to: dest) }
            else { await VLCProbe.writeThumbnail(for: fileURL, position: 0.12, to: dest) }
        }
        items.insert(item, at: 0)
    }

    func rescan() async {
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
            for f in files where MediaKinds.media.contains(f.pathExtension.lowercased()) {
                if !items.contains(where: { $0.folderID == nil && $0.fileName == f.lastPathComponent }) { await ingest(fileURL: f) }
            }
        }
        await scanFolders(); await backfillDurations(); pruneMissing(); save()
    }

    func pruneMissing() {
        var missing: [UUID: (gone: Int, total: Int)] = [:]
        for item in items {
            guard let folderID = item.folderID, !isOffline(item) else { continue }
            var tally = missing[folderID] ?? (0, 0); tally.total += 1
            if !fm.fileExists(atPath: url(for: item).path) { tally.gone += 1 }
            missing[folderID] = tally
        }

        let unreachable = Set(missing.compactMap { (id, tally) in (tally.total > 1 && tally.gone == tally.total) ? id : nil })
        let failedToResolve = folders.map(\.id).filter { folderURLs[$0] == nil }
        let combined = unreachable.union(failedToResolve)
        if combined != unreachableFolders { unreachableFolders = combined }

        items.removeAll { item in
            if let folderID = item.folderID { if isOffline(item) || unreachable.contains(folderID) { return false } }
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
        var next = 0, done = 0

        await withTaskGroup(of: (UUID, MediaMetadata?).self) { group in
            func enqueue() {
                if next < snapshot.count {
                    let item = snapshot[next]; next += 1
                    group.addTask { (item.id, await MetadataService.fetchMetadata(for: item.fileName, cleanTitle: Self.prettyTitle(from: (item.fileName as NSString).deletingPathExtension))) }
                }
            }
            for _ in 0..<concurrency { enqueue() }
            while let (id, meta) = await group.next() {
                done += 1; refreshProgress = (done, snapshot.count)
                if let meta, let index = items.firstIndex(where: { $0.id == id }) { items[index].metadata = meta }
                enqueue()
            }
        }
        save()
    }

    func updateProgress(id: UUID, position: Double, duration: Double) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].lastPosition = max(0, position); if duration > 0 { items[i].duration = duration }; items[i].lastPlayed = Date(); save() }
    }

    func backfillDurations() async {
        for item in items.filter({ $0.duration <= 0 }) {
            guard !isOffline(item), let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            let targetURL = url(for: item)
            items[index].duration = await VLCProbe.duration(of: targetURL)
        }
        save()
    }

    func resetProgress(_ item: MediaItem) { resetProgress([item]) }
    func resetProgress(_ batch: [MediaItem]) { for item in batch { if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].lastPosition = 0 } }; save() }
    func markWatched(_ item: MediaItem) { markWatched([item]) }
    func markWatched(_ batch: [MediaItem]) { for item in batch { if let i = items.firstIndex(where: { $0.id == item.id }), items[i].duration > 0 { items[i].lastPosition = items[i].duration; items[i].lastPlayed = Date() } }; save() }
    func rename(_ item: MediaItem, to newTitle: String) { if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].title = newTitle; save() } }
    
    func delete(_ item: MediaItem) {
        let target = url(for: item), thumb = thumbURL(for: item), sub = savedSubtitleURL(for: item), isExt = item.isExternal, offline = isOffline(item)
        items.removeAll { $0.id == item.id }; save()
        
        Task.detached(priority: .userInitiated) {
            let localFm = FileManager.default
            if !offline {
                if localFm.fileExists(atPath: target.path) { try? localFm.removeItem(at: target) }
                if !isExt { 
                    let sidecar = target.deletingPathExtension().appendingPathExtension("srt")
                    if localFm.fileExists(atPath: sidecar.path) { try? localFm.removeItem(at: sidecar) }
                }
            }
            if localFm.fileExists(atPath: thumb.path) { try? localFm.removeItem(at: thumb) }
            if localFm.fileExists(atPath: sub.path) { try? localFm.removeItem(at: sub) }
        }
    }
    
    func clearProgress() { for i in items.indices { items[i].lastPosition = 0; items[i].lastPlayed = nil }; save() }
    
    func deleteAll() {
        for item in items {
            if item.folderID == nil { 
                let target = url(for: item)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            }
            let thumb = thumbURL(for: item)
            let sub = savedSubtitleURL(for: item)
            if fm.fileExists(atPath: thumb.path) { try? fm.removeItem(at: thumb) }
            if fm.fileExists(atPath: sub.path) { try? fm.removeItem(at: sub) }
        }
        
        for task in watcherTasks.values { task.cancel() }
        watcherTasks.removeAll()
        Task { await watcher.stopAll() }
        
        watchedDirectories.removeAll()
        for url in folderURLs.values { url.stopAccessingSecurityScopedResource() }
        folderURLs.removeAll(); folders.removeAll(); items.removeAll()
        saveFolders(); save()
    }

    func storageString() -> String { "Calculating…" }

    func calculateStorageAsync() async -> String {
        let targetPath = mediaDir
        let totalBytes = await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let localFm = FileManager.default
            if let enumerator = localFm.enumerator(at: targetPath, includingPropertiesForKeys: [.fileSizeKey]) {
                while let f = enumerator.nextObject() as? URL {
                    if let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
                }
            }
            return total
        }.value
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    // MARK: - Helpers
    nonisolated static func prettyTitle(from raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        if !s.contains(" ") { s = s.replacingOccurrences(of: ".", with: " ") }
        let lower = s.lowercased()
        let markers = ["1080p", "720p", "2160p", "480p", "4k", "x264", "x265", "h264", "h265", "hevc", "web-dl", "webdl", "webrip", "bluray", "brrip", "bdrip", "hdrip", "hdtv", "dvdrip", "remux", "10bit", "yify", "rarbg", "aac"]
        var cut = s.count
        for m in markers { if let r = lower.range(of: m) { cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound)) } }
        if cut < s.count { s = String(s.prefix(cut)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -._[]()"))
        if let regex = try? NSRegularExpression(pattern: "(?i)s\\d{1,2}e\\d{1,2}.*") { s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines) }
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
