import Foundation
import SwiftData

@Model
final class WatchedFolder: Identifiable, Hashable, Codable {
    @Attribute(.unique) var id: UUID
    var name: String
    var bookmark: Data
    var dateAdded: Date

    init(id: UUID = UUID(), name: String, bookmark: Data, dateAdded: Date = Date()) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.dateAdded = dateAdded
    }

    // MARK: - Legacy JSON Migration Support
    enum CodingKeys: String, CodingKey {
        case id, name, bookmark, dateAdded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.bookmark = try container.decode(Data.self, forKey: .bookmark)
        self.dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bookmark, forKey: .bookmark)
        try container.encode(dateAdded, forKey: .dateAdded)
    }
}

// MARK: - Folder Watcher Actor
actor FolderWatcher {
    static let maxDirectories = 64

    private final class Handle: @unchecked Sendable {
        let source: DispatchSourceFileSystemObject
        let descriptor: Int32
        init(source: DispatchSourceFileSystemObject, descriptor: Int32) {
            self.source = source
            self.descriptor = descriptor
        }
        deinit {
            source.cancel()
            close(descriptor)
        }
    }

    private var activeHandles: [UUID: [Handle]] = [:]
    private let queue = DispatchQueue(label: "com.polao.minaanii.folderwatcher", qos: .utility)

    /// Monitors the given directories and returns an AsyncStream that yields whenever a change occurs.
    func watch(folderID: UUID, directories: [URL]) -> AsyncStream<Void> {
        stop(folderID: folderID)

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        
        var created: [Handle] = []
        for directory in directories.prefix(Self.maxDirectories) {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: queue
            )

            source.setEventHandler {
                continuation.yield()
            }

            source.resume()
            created.append(Handle(source: source, descriptor: descriptor))
        }

        activeHandles[folderID] = created

        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(folderID: folderID) }
        }
        
        return stream
    }

    func stop(folderID: UUID) {
        activeHandles.removeValue(forKey: folderID)
    }

    func stopAll() {
        activeHandles.removeAll()
    }
}
