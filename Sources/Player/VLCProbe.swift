// ==========================================================
//  IMPROVEMENT 1  -  MKV DURATION AND THUMBNAILS  (file 1 of 2)
//
//  File:  Sources/Player/VLCProbe.swift
// ==========================================================

import Foundation
import UIKit
import CoreGraphics
import MobileVLCKit

enum VLCProbe {

    /// Length in seconds, or 0 if VLC cannot work it out.
    ///
    /// This blocks the calling thread for up to ten seconds. Never call it
    /// on the main thread. LibraryStore hands it to a detached task.
    nonisolated static func duration(of url: URL) -> Double {
        let media = VLCMedia(url: url)

        // Local parse only. No network fetch, no cover art, no user interaction.
        // Swift 6 / Modern MobileVLCKit drops the zero-value .parseLocal and uses parse(options:)
        _ = media.parse(options: [.fetchLocal])

        let parsed: VLCTime? = media.lengthWait(until: Date().addingTimeInterval(10))
        let milliseconds = Double(parsed?.intValue ?? 0)
        guard milliseconds > 0 else { return 0 }
        return milliseconds / 1000
    }

    /// Grabs a frame at `position` (0 to 1) and writes it as a JPEG.
    /// Suspends rather than blocks, so calling it from the main actor is fine.
    @MainActor
    static func writeThumbnail(for url: URL, position: Float, to destination: URL) async {
        let grabber = VLCFrameGrabber()
        guard let image = await grabber.image(for: url, position: position),
              let data = image.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}

// MARK: - Frame grabber

/// Wraps VLCMediaThumbnailer's delegate callbacks in an async call.
///
/// The thumbnailer holds its delegate weakly and does not retain its media,
/// so this object owns both for the duration of the fetch. It also owns a
/// watchdog: if libvlc neither finishes nor times out, the continuation
/// would otherwise be leaked and the awaiting task hung forever.
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

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        let image = UIImage(cgImage: thumbnail)
        Task { @MainActor [weak self] in self?.finish(image) }
    }

    /// Idempotent. Whichever of the three paths arrives first wins.
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
