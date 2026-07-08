import Foundation

enum MediaKinds {
    static let video: Set<String> = ["mp4", "m4v", "mov", "3gp", "mkv", "avi", "webm", "ts", "m2ts", "mts", "flv", "wmv", "mpg", "mpeg", "vob", "ogv"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "caf", "aif", "aiff", "flac", "ogg", "opus", "wma"]
    static let subtitles: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]
    static let native: Set<String> = ["mp4", "m4v", "mov", "3gp", "mp3", "m4a", "aac", "wav", "caf", "aif", "aiff", "flac"]
    static var media: Set<String> { video.union(audio) }
}

struct MediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var dateAdded: Date = Date()
    var duration: Double = 0
    var lastPosition: Double = 0
    var lastPlayed: Date? = nil
    var metadata: MediaMetadata? = nil

    var progress: Double { guard duration > 0 else { return 0 }; return min(max(lastPosition / duration, 0), 1) }
    var isWatched: Bool { duration > 0 && progress >= 0.95 }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    var isAudio: Bool { MediaKinds.audio.contains(fileExtension) }
    var isEngineSupported: Bool { MediaKinds.native.contains(fileExtension) }
}
