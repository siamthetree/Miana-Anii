import Foundation

struct WatchedFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var bookmark: Data
    var dateAdded: Date = Date()
}

/// A fully Swift 6 compliant background actor that monitors the file system 
/// and yields events cleanly using modern AsyncStreams.
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

        // When the stream is cancelled by the observer, clean up the handles safely
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(folderID: folderID) }
        }
        
        return stream
    }

    func stop(folderID: UUID) {
        // Removing the array triggers deinit on all Handles, automatically cancelling sources and closing descriptors.
        activeHandles.removeValue(forKey: folderID)
    }

    func stopAll() {
        activeHandles.removeAll()
    }
}
