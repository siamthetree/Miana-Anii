import Foundation
import UIKit
import CoreGraphics
import MobileVLCKit

enum VLCProbe {

    /// Length in seconds, or 0 if VLC cannot work it out.
    nonisolated static func duration(of url: URL) -> Double {
        let media = VLCMedia(url: url)

        // FIX: Replaced C-style bitwise OR with the correct Swift array syntax for OptionSet
        _ = media.parse(options: [.fetchLocal])

        let parsed: VLCTime? = media.lengthWait(until: Date().addingTimeInterval(10))
        let milliseconds = Double(parsed?.intValue ?? 0)
        guard milliseconds > 0 else { return 0 }
        return milliseconds / 1000
    }

    /// Grabs a frame at `position` (0 to 1) and writes it as a JPEG.
    @MainActor
    static func writeThumbnail(for url: URL, position: Float, to destination: URL) async {
        let grabber = VLCFrameGrabber()
        guard let image = await grabber.image(for: url, position: position),
              let data = image.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}

// MARK: - Frame grabber

@MainActor
private final class VLCFrameGrabber: NSObject, VLCMediaThumbnailerDelegate {

    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var thumbnailer: VLCMediaThumbnailer?
    private var media: VLCMedia?
    private var watchdog: Task<Void, Never>?

    func image(for url: URL, position: Float) async -> UIImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let media = VLCMedia(url: url)
            self.media = media

            let thumbnailer: VLCMediaThumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
            thumbnailer.snapshotPosition = position
            thumbnailer.thumbnailWidth = 640
            thumbnailer.thumbnailHeight = 360
            self.thumbnailer = thumbnailer

            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }

            thumbnailer.fetchThumbnail()
        }
    }

    // FIX: Updated to non-optional parameters to match modern SDK headers
    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        let image = UIImage(cgImage: thumbnail)
        Task { @MainActor [weak self] in self?.finish(image) }
    }

    private func finish(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel()
        watchdog = nil
        thumbnailer = nil
        media = nil
        continuation.resume(returning: image)
    }
}
