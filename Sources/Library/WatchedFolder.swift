import Foundation

struct WatchedFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var bookmark: Data
    var dateAdded: Date = Date()
}

@MainActor
final class FolderWatcher {

    /// Ceiling on descriptors opened per watched folder.
    static let maxDirectories = 64

    private final class Handle {
        let source: DispatchSourceFileSystemObject
        init(source: DispatchSourceFileSystemObject) { self.source = source }
    }

    private var handles: [UUID: [Handle]] = [:]
    private let queue = DispatchQueue(label: "com.polao.minaanii.folderwatcher", qos: .utility)

    /// Watches `directories` and calls `onChange` off the main thread whenever
    /// any of them gains, loses or renames an entry.
    func watch(folderID: UUID, directories: [URL], onChange: @escaping @Sendable () -> Void) {
        stop(folderID: folderID)

        var created: [Handle] = []
        for directory in directories.prefix(Self.maxDirectories) {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: queue
            )
            
            // SWIFT 6 FIX: Explicitly mark closures as @Sendable to strip them of
            // their @MainActor isolation. This stops the app from crashing when GCD
            // fires these events on the background queue.
            source.setEventHandler { @Sendable in 
                onChange() 
            }
            
            source.setCancelHandler { @Sendable [descriptor] in 
                close(descriptor) 
            }
            
            source.resume()
            created.append(Handle(source: source))
        }
        handles[folderID] = created
    }

    func stop(folderID: UUID) {
        handles[folderID]?.forEach { $0.source.cancel() }
        handles[folderID] = nil
    }

    func stopAll() {
        for id in Array(handles.keys) { stop(folderID: id) }
    }
}
