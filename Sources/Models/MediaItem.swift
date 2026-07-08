import Foundation

struct MediaItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var fileURL: URL
    var createdAt: Date
    var metadata: MediaMetadata?

    init(
        id: UUID = UUID(),
        title: String,
        fileURL: URL,
        createdAt: Date = Date(),
        metadata: MediaMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.metadata = metadata
    }
}
