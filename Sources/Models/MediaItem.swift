import Foundation
import SwiftData

@Model
final class MediaItem: Identifiable, Codable {
    @Attribute(.unique) var id: UUID
    var title: String
    var fileName: String
    var dateAdded: Date
    var duration: Double
    var lastPosition: Double
    var lastPlayed: Date?
    var metadata: MediaMetadata?
    var folderID: UUID?
    var relativePath: String?

    init(title: String, fileName: String, id: UUID = UUID(), dateAdded: Date = Date(), duration: Double = 0, lastPosition: Double = 0, lastPlayed: Date? = nil, metadata: MediaMetadata? = nil, folderID: UUID? = nil, relativePath: String? = nil) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.dateAdded = dateAdded
        self.duration = duration
        self.lastPosition = lastPosition
        self.lastPlayed = lastPlayed
        self.metadata = metadata
        self.folderID = folderID
        self.relativePath = relativePath
    }

    // MARK: - Legacy JSON Migration Support
    enum CodingKeys: String, CodingKey {
        case id, title, fileName, dateAdded, duration, lastPosition, lastPlayed, metadata, folderID, relativePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        self.lastPosition = try container.decodeIfPresent(Double.self, forKey: .lastPosition) ?? 0
        self.lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        self.metadata = try container.decodeIfPresent(MediaMetadata.self, forKey: .metadata)
        self.folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        self.relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(duration, forKey: .duration)
        try container.encode(lastPosition, forKey: .lastPosition)
        try container.encode(lastPlayed, forKey: .lastPlayed)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(folderID, forKey: .folderID)
        try container.encode(relativePath, forKey: .relativePath)
    }
}

// Keep these as plain structs; SwiftData handles them as embedded complex types
struct MediaMetadata: Codable, Hashable {
    var title: String?
    var overview: String?
    var releaseYear: String?
    var posterURL: URL?
    var backdropURL: URL?
    var rating: Double?
    var genres: [String]
    var cast: [String]
}

struct Series: Identifiable, Hashable {
    let id: String
    let title: String
    let posterURL: URL?
    let backdropURL: URL?
    let overview: String
    let releaseYear: String
    let rating: Double?
    let genres: [String]
    let cast: [String]
    let episodes: [MediaItem]
}
