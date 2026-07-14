import Foundation
import UIKit
import CoreGraphics
import MobileVLCKit

enum VLCProbe {

    /// Safely fetches the length of a video in seconds without blocking the thread.
    @MainActor
    static func duration(of url: URL) async -> Double {
        let parser = VLCMediaParser()
        return await parser.parse(url: url)
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

// MARK: - Safe Media Parser
/// Replaces the thread-crashing `lengthWait` method with a safe, asynchronous delegate.
@MainActor
private final class VLCMediaParser: NSObject, VLCMediaDelegate {
    private var continuation: CheckedContinuation<Double, Never>?
    private var media: VLCMedia?
    private var watchdog: Task<Void, Never>?

    func parse(url: URL) async -> Double {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            
            let media = VLCMedia(url: url)
            self.media = media
            media.delegate = self
            
            // Failsafe: If VLC hangs on a corrupted file, abort after 5 seconds
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(0)
            }
            
            media.parse(options: [.fetchLocal])
        }
    }

    nonisolated func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        let ms = aMedia.length.value?.doubleValue ?? 0
        Task { @MainActor [weak self] in self?.finish(ms > 0 ? ms / 1000 : 0) }
    }

    private func finish(_ duration: Double) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel()
        watchdog = nil
        media?.delegate = nil
        media = nil
        continuation.resume(returning: duration)
    }
}

// MARK: - Frame Grabber
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

            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
            thumbnailer.snapshotPosition = position
            thumbnailer.thumbnailWidth = 640
            thumbnailer.thumbnailHeight = 360
            self.thumbnailer = thumbnailer

            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }

            thumbnailer.fetchThumbnail()
        }
    }

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
