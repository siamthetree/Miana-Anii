// ==========================================================
//  IMPROVEMENT 1  -  MKV DURATION AND THUMBNAILS  (file 1 of 2)
//
//  File to CREATE:  Sources/Player/VLCProbe.swift
//  On GitHub: open Sources/Player, "Add file" > "Create new file",
//  name it VLCProbe.swift, paste this in, commit.
//
//  THE BUG
//  -------
//  ingest() asked AVURLAsset for the duration of every file. AVFoundation
//  cannot open Matroska, AVI, WebM or MPEG-TS, so every .mkv landed in the
//  library with duration = 0. Follow that thread:
//
//    - Continue Watching filters on duration > 0, so mkv never appeared
//    - isWatched is progress >= 0.95, and progress divides by duration,
//      so an mkv could never be marked watched
//    - the Trakt check-in guards on duration > 0, so it never fired
//    - the duration pill on the card stayed blank
//
//  Every one of those is the same missing number.
//
//  The frame grab failed for the same reason. AVAssetImageGenerator
//  returned nil, so the card fell back to the film icon unless TMDB had
//  matched a poster.
//
//  THE FIX
//  -------
//  VLC already ships in this app and reads all of it. Ask VLC instead when
//  AVFoundation cannot help.
//
//  Note the deliberate "let parsed: VLCTime?" and "let cgImage: CGImage?"
//  lines. MobileVLCKit's headers carry no nullability annotations, so those
//  values arrive as implicitly unwrapped optionals. Binding them through an
//  explicit optional type compiles whether or not that ever changes.
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
        // If a future MobileVLCKit turns VLCMediaParsingOptions into an
        // NS_OPTIONS type, this becomes .parseLocal and .fetchLocal.
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

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer!) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer!, didFinishThumbnail thumbnail: CGImage!) {
        let cgImage: CGImage? = thumbnail
        let image = cgImage.map { UIImage(cgImage: $0) }
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
