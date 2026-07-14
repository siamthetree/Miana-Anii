// ==========================================================
//  BUG 6  -  SUBTITLE LOOKUP SCANNED EVERY CUE, EVERY TICK
//
//  File:  Sources/Player/PlayerVM & PlayerScreen.swift
//  Replace the entire file. Supersedes BUG-4b.
//
//  SRTParser.cue did cues.first(where:) on every clock tick. Four ticks a
//  second, against a two hour film's two thousand cues, is a great many
//  string comparisons thrown away.
//
//  Playback moves forward, so the cue we want is almost always the one we
//  showed last, or the one after it. updateCue keeps a cursor and walks
//  from there. Typically a step or two.
//
//  The cursor walks backwards as readily as forwards, so a seek needs no
//  special handling: it finds its way from wherever it was. It resets to
//  zero only when the cue list itself is replaced.
//
//  cueText is only assigned when it actually changes, so an unchanged cue
//  no longer publishes a redraw four times a second.
// ==========================================================

import Foundation
import SwiftUI
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit
import UniformTypeIdentifiers
import MobileVLCKit

@MainActor
final class PlayerVM: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let store: LibraryStore; let media: MediaItem; let player = AVPlayer(); let layerHolder = PlayerLayerHolder(); let vlcPlayer = VLCMediaPlayer()

    @Published var isPlaying = false; @Published var current: Double = 0; @Published var duration: Double = 0; @Published var rate: Double = 1.0; @Published var showControls = true; @Published var isScrubbing = false; @Published var fillScreen = false; @Published var cueText: String?; @Published var subtitlesOn = true; @Published var hasExternalCues = false; @Published var errorMessage: String?; @Published var audioOptions: [AVMediaSelectionOption] = []; @Published var legibleOptions: [AVMediaSelectionOption] = []; @Published var volumeLevel: Double = 1.0; @Published var flashText: String?
    @Published var vlcSubtitleTracks: [PlayerTrack] = []; @Published var vlcAudioTracks: [PlayerTrack] = []
    @Published var vlcSubtitleIndex: Int32 = -1; @Published var vlcAudioIndex: Int32 = -1

    private var audioGroup: AVMediaSelectionGroup?; private var legibleGroup: AVMediaSelectionGroup?; private var cues: [SubtitleCue] = []; private var timeObserver: Any?; private var statusCancellable: AnyCancellable?; private var endObserver: NSObjectProtocol?; private var lastSave = Date.distantPast; private var hideTask: DispatchWorkItem?; private var flashTask: DispatchWorkItem?; private var pip: AVPictureInPictureController?; private var pendingVLCSeek: Double?

    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var audioObservers: [NSObjectProtocol] = []
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var resumeAfterInterruption = false
    private var lastNowPlayingDuration: Double = -1
    private var cueCursor = 0
    private var didAutoSelectSubtitle = false
    private var hasScrobbledWatched = false
    private var isScrobbling = false

    /// Trakt checks the title in as watched once this much time is left.
    private static let watchedSecondsRemaining: Double = 180

    init(media: MediaItem, store: LibraryStore) { self.media = media; self.store = store; super.init() }

    func start() {
        configureAudioSession()
        setupRemoteCommands()
        observeAudioSession()
        Task { @MainActor [weak self] in await self?.loadArtwork() }
        let url = store.url(for: media); let defaults = UserDefaults.standard
        if defaults.object(forKey: "defaultRate") != nil { rate = defaults.double(forKey: "defaultRate") }; if rate <= 0 { rate = 1 }
        let autoResume = (defaults.object(forKey: "autoResume") as? Bool) ?? true
        let shouldResume = autoResume && media.lastPosition > 15 && media.duration > 0 && media.lastPosition < media.duration * 0.95

        if media.isEngineSupported {
            let item = AVPlayerItem(url: url); player.replaceCurrentItem(with: item); player.allowsExternalPlayback = true; player.volume = Float(volumeLevel)
            statusCancellable = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in guard let self else { return }; if status == .readyToPlay, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d } }
            
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in 
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPlaying = false; self.showControls = true
                    if self.duration > 0 { self.store.updateProgress(id: self.media.id, position: self.duration, duration: self.duration) }
                    self.scrobbleWatched()
                }
            }
            loadSelectionGroups(for: item)

            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in 
                Task { @MainActor [weak self] in
                    guard let self, !self.isScrubbing else { return }
                    self.current = time.seconds
                    if self.duration <= 0, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                    self.updateCue(at: time.seconds)
                    if self.duration != self.lastNowPlayingDuration { self.updateNowPlaying() }
                    self.periodicSave()
                    self.checkWatchedThreshold()
                }
            }
            if shouldResume { player.seek(to: CMTime(seconds: media.lastPosition, preferredTimescale: 600)); current = media.lastPosition }
        } else {
            vlcPlayer.delegate = self; vlcPlayer.media = VLCMedia(url: url); vlcPlayer.audio?.volume = Int32(volumeLevel * 100)
            vlcPlayer.audio?.passthrough = UserDefaults.standard.bool(forKey: "audioPassthrough")
            if shouldResume { self.pendingVLCSeek = media.lastPosition }
        }
        loadSidecarSubtitles(for: url); play(); scheduleAutoHide()

        // VLC does not publish its elementary streams the instant playback
        // begins. State changes usually cover it; this catches the rest.
        if !media.isEngineSupported {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refreshVLCTracks()
            }
        }
    }

    func stop() {
        saveNow()
        checkWatchedThreshold()
        scrobbleAbandon()
        statusCancellable = nil; if let observer = timeObserver { player.removeTimeObserver(observer); timeObserver = nil }; if let end = endObserver { NotificationCenter.default.removeObserver(end); endObserver = nil }
        hideTask?.cancel(); flashTask?.cancel()
        if media.isEngineSupported { player.pause(); player.replaceCurrentItem(with: nil) } else { vlcPlayer.stop(); vlcPlayer.delegate = nil }
        teardownRemoteControl()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            switch self.vlcPlayer.state {
            case .playing: self.isPlaying = true; if let dur = self.vlcPlayer.media?.length.value?.doubleValue, dur > 0, self.duration <= 0 { self.duration = dur / 1000.0 }; if let target = self.pendingVLCSeek { self.vlcPlayer.time = VLCTime(int: Int32(target * 1000)); self.current = target; self.pendingVLCSeek = nil }
            case .paused: self.isPlaying = false
            case .ended: self.isPlaying = false; self.showControls = true; if self.duration > 0 { self.store.updateProgress(id: self.media.id, position: self.duration, duration: self.duration) }; self.scrobbleWatched()
            case .error: self.errorMessage = "VLC encountered an error reading this file. It may be corrupted."
            default: break
            }
            self.refreshVLCTracks()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in 
            guard !self.isScrubbing else { return }
            let ms = self.vlcPlayer.time.value?.doubleValue ?? 0
            self.current = ms / 1000.0
            if self.duration <= 0, let dur = self.vlcPlayer.media?.length.value?.doubleValue, dur > 0 { self.duration = dur / 1000.0 }
            self.updateCue(at: self.current)
            if self.duration != self.lastNowPlayingDuration { self.updateNowPlaying() }
            self.periodicSave()
            self.checkWatchedThreshold() 
        }
    }

    // MARK: - Trakt

    /// Falls back to the stored progress before the engine reports a duration.
    private var scrobbleProgress: Double {
        guard duration > 0 else { return media.progress }
        return min(max(current / duration, 0), 1)
    }

    /// Opens a scrobble. Silent once the title has been checked in.
    private func scrobbleStart() {
        guard !hasScrobbledWatched else { return }
        isScrobbling = true
        TraktService.shared.scrobble(item: media, progress: scrobbleProgress, action: .start)
    }

    private func scrobblePause() {
        guard !hasScrobbledWatched, isScrobbling else { return }
        isScrobbling = false
        TraktService.shared.scrobble(item: media, progress: scrobbleProgress, action: .pause)
    }

    /// Checks the title in as watched. Reports 100 percent so Trakt writes it
    /// to history regardless of the account's scrobble threshold.
    private func scrobbleWatched() {
        guard !hasScrobbledWatched else { return }
        hasScrobbledWatched = true
        isScrobbling = false
        TraktService.shared.scrobble(item: media, progress: 1.0, action: .stop)
    }

    /// Closing the player early. Reports the real position, so Trakt keeps it
    /// in progress rather than marking it watched.
    private func scrobbleAbandon() {
        guard !hasScrobbledWatched, isScrobbling else { return }
        isScrobbling = false
        TraktService.shared.scrobble(item: media, progress: scrobbleProgress, action: .stop)
    }

    /// Three minutes from the end, check in. Under six minutes long the three
    /// minute rule would fire near the start, so use 90 percent instead.
    private func checkWatchedThreshold() {
        guard !hasScrobbledWatched, duration > 0, current > 0 else { return }
        let remaining = duration - current
        let reachedEnd = duration > 360
            ? remaining <= Self.watchedSecondsRemaining
            : (current / duration) >= 0.90
        if reachedEnd { scrobbleWatched() }
    }

    func play() {
        if media.isEngineSupported { player.playImmediately(atRate: Float(rate)) } else { vlcPlayer.play(); if rate != 1.0 { vlcPlayer.rate = Float(rate) } }
        isPlaying = true
        scheduleAutoHide()
        scrobbleStart()
        updateNowPlaying()
    }

    func pause() {
        if media.isEngineSupported { player.pause() } else { vlcPlayer.pause() }
        isPlaying = false; saveNow()
        hideTask?.cancel()
        scrobblePause()
        updateNowPlaying()
    }

    func toggleControls() { 
        showControls.toggle()
        if showControls { 
            scheduleAutoHide() 
        } else {
            hideTask?.cancel()
        } 
    }

    func seek(to target: Double) { let clamped = min(max(target, 0), duration > 0 ? max(duration - 0.5, 0) : target); if media.isEngineSupported { player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) } else { vlcPlayer.time = VLCTime(int: Int32(clamped * 1000)) }; current = clamped; scheduleAutoHide(); updateNowPlaying() }
    func skip(_ seconds: Double) { seek(to: current + seconds); flash(seconds >= 0 ? "+\(Int(seconds))s" : "\(Int(seconds))s") }
    func setRate(_ newRate: Double) { rate = newRate; UserDefaults.standard.set(newRate, forKey: "defaultRate"); if isPlaying { if media.isEngineSupported { player.rate = Float(newRate) } else { vlcPlayer.rate = Float(newRate) } }; flash(String(format: "%.2gx", newRate)); updateNowPlaying() }
    func setVolume(_ value: Double) { volumeLevel = min(max(value, 0), 1); if media.isEngineSupported { player.volume = Float(volumeLevel) } else { vlcPlayer.audio?.volume = Int32(volumeLevel * 100) }; flash("Volume \(Int(volumeLevel * 100))%") }

    func scheduleAutoHide() { 
        hideTask?.cancel()
        guard isPlaying else { return }

        let intervalObject = UserDefaults.standard.object(forKey: "autoHideInterval")
        let interval = intervalObject != nil ? UserDefaults.standard.double(forKey: "autoHideInterval") : 10.0

        guard interval > 0 else { return }

        let work = DispatchWorkItem { [weak self] in 
            guard let self, self.isPlaying, !self.isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.showControls = false } 
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work) 
    }

    func flash(_ text: String) { flashText = text; flashTask?.cancel(); let work = DispatchWorkItem { [weak self] in self?.flashText = nil }; flashTask = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work) }

    /// Playback moves forward, so the cue we want is almost always the one we
    /// showed last or the one after it. Remembering where we were turns a linear
    /// scan of every cue, on every clock tick, into a step or two.
    ///
    /// Four ticks a second against a two hour film's two thousand cues is a lot of
    /// string comparisons to throw away.
    private func updateCue(at time: Double) {
        guard subtitlesOn, hasExternalCues, !cues.isEmpty else {
            if cueText != nil { cueText = nil }
            return
        }

        // A seek can land anywhere; walk backwards until we are not past the cue.
        while cueCursor > 0 && time < cues[cueCursor].start {
            cueCursor -= 1
        }
        // Skip anything that has already ended.
        while cueCursor < cues.count - 1 && time > cues[cueCursor].end {
            cueCursor += 1
        }

        let cue = cues[cueCursor]
        let text = (time >= cue.start && time <= cue.end) ? cue.text : nil
        if text != cueText { cueText = text }
    }

    /// One you loaded in the player wins, since you chose it. Otherwise an .srt
    /// already sitting next to the video, which is only ever read.
    private func loadSidecarSubtitles(for mediaURL: URL) {
        let saved = store.savedSubtitleURL(for: media)
        if FileManager.default.fileExists(atPath: saved.path) {
            loadSubtitleFile(saved, persist: false)
            return
        }
        let sidecar = mediaURL.deletingPathExtension().appendingPathExtension("srt")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            loadSubtitleFile(sidecar, persist: false)
        }
    }
    /// persist: true keeps the subtitle for next time, in the app's own Subtitles
    /// directory. It used to write it next to the video, which for a media source
    /// meant dropping a file onto the user's own drive: uninvited, silent if the
    /// volume was read only, and enough to wake the folder watcher.
    func loadSubtitleFile(_ url: URL, persist: Bool = true) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { flash("Couldn't read subtitles"); return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let parsed = SRTParser.parse(text)
        guard !parsed.isEmpty else { flash("Couldn't read subtitles"); return }

        cues = parsed
        cueCursor = 0
        hasExternalCues = true
        subtitlesOn = true
        flash("Subtitles loaded")

        if persist { try? data.write(to: store.savedSubtitleURL(for: media), options: .atomic) }
    }
    private func loadSelectionGroups(for item: AVPlayerItem) { let asset = item.asset; Task { [weak self] in let chars = (try? await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)) ?? []; let audio = chars.contains(.audible) ? try? await asset.loadMediaSelectionGroup(for: .audible) : nil; let legible = chars.contains(.legible) ? try? await asset.loadMediaSelectionGroup(for: .legible) : nil; guard let self else { return }; self.audioGroup = audio; self.legibleGroup = legible; self.audioOptions = audio?.options ?? []; self.legibleOptions = legible?.options ?? [] } }
    // MARK: - Lock screen, headphones and interruptions

    /// UIBackgroundModes already lets audio survive the screen locking, but
    /// nothing was telling iOS what was playing or listening for the buttons
    /// on the lock screen and on headphones. This does both.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        addCommand(center.playCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.play() }
            return .success
        }
        addCommand(center.pauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }
        addCommand(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in if self.isPlaying { self.pause() } else { self.play() } }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        addCommand(center.skipForwardCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(15) }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        addCommand(center.skipBackwardCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(-15) }
            return .success
        }

        addCommand(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self.seek(to: position) }
            return .success
        }
    }

    /// The guard-let-self dance is deliberate. A weak capture is a variable owned
    /// by this closure, and the Task inside runs concurrently, so it cannot read
    /// it. Pinning it to a local constant first is what makes this compile.
    private func addCommand(_ command: MPRemoteCommand,
                            _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        remoteTargets.append((command, command.addTarget(handler: handler)))
    }

    private func observeAudioSession() {
        let notifications = NotificationCenter.default

        // A phone call, a Siri request, another app grabbing the session.
        audioObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                        object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            switch type {
            case .began:
                Task { @MainActor in
                    self.resumeAfterInterruption = self.isPlaying
                    if self.isPlaying { self.pause() }
                }
            case .ended:
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                Task { @MainActor in
                    guard self.resumeAfterInterruption, options.contains(.shouldResume) else { return }
                    self.resumeAfterInterruption = false
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.play()
                }
            @unknown default:
                break
            }
        })

        // Two jobs. Pause when the old output disappears, so pulling headphones
        // out does not dump the audio onto the iPad speaker at whatever volume it
        // happened to be at. And re-ask for the channel count, because plugging
        // into a receiver mid-film is exactly when more than two become available.
        audioObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                        object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }

            Task { @MainActor in
                self.applyPreferredChannels()
                if reason == .oldDeviceUnavailable, self.isPlaying { self.pause() }
            }
        })
    }

    /// .moviePlayback already asks for spatialisation on AirPods. What was missing
    /// is the declaration that this app has multichannel content to spatialise:
    /// without it, AirPlay and HDMI stay stereo and a 5.1 mix is folded down
    /// before it ever leaves the device.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
        applyPreferredChannels()
    }

    /// Ask the current route for everything it has. Two on the built-in speaker,
    /// more over USB-C to HDMI or a digital receiver.
    private func applyPreferredChannels() {
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
    }

    private func teardownRemoteControl() {
        for (command, token) in remoteTargets { command.removeTarget(token) }
        remoteTargets.removeAll()
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        audioObservers.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// iOS extrapolates the elapsed time from the rate, so this only needs to
    /// run when something other than the clock changes.
    private func updateNowPlaying() {
        lastNowPlayingDuration = duration

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
        info[MPNowPlayingInfoPropertyMediaType] = (media.isAudio ? MPNowPlayingInfoMediaType.audio : MPNowPlayingInfoMediaType.video).rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private var nowPlayingTitle: String {
        media.isEpisode ? media.displayEpisodeTitle : (media.metadata?.title ?? media.title)
    }

    private var nowPlayingSubtitle: String {
        if media.isEpisode, let show = media.metadata?.title, !show.isEmpty {
            return media.episodeNumber > 0 ? "\(show) • \(media.episodeCode)" : show
        }
        if let year = media.metadata?.releaseYear, !year.isEmpty { return year }
        return media.fileExtension.uppercased()
    }

    /// Local frame grab first, since it works offline. TMDB poster as a fallback.
    private func loadArtwork() async {
        let path = store.thumbURL(for: media).path
        var image: UIImage? = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value

        if image == nil, let poster = media.metadata?.posterURL,
           let (data, _) = try? await URLSession.shared.data(from: poster) {
            image = UIImage(data: data)
        }
        guard let image else { return }

        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateNowPlaying()
    }

    // MARK: - VLC tracks

    var usesVLC: Bool { !media.isEngineSupported }

    /// AVFoundation exposes embedded tracks through AVMediaSelectionGroup, which
    /// only ever gets loaded on the AVPlayer path. Files that fall through to VLC
    /// had no track list at all, so an mkv with embedded subtitles showed nothing
    /// and the menu offered only "Load .srt file". These are the VLC equivalents.
    private func refreshVLCTracks() {
        guard usesVLC else { return }

        vlcSubtitleTracks = Self.trackList(indexes: vlcPlayer.videoSubTitlesIndexes, names: vlcPlayer.videoSubTitlesNames)
        vlcAudioTracks = Self.trackList(indexes: vlcPlayer.audioTrackIndexes, names: vlcPlayer.audioTrackNames)
        vlcSubtitleIndex = vlcPlayer.currentVideoSubTitleIndex
        vlcAudioIndex = vlcPlayer.currentAudioTrackIndex

        // VLC leaves subtitles off unless a track matches the preferred language.
        // Turn the first one on once, so a subtitled file plays subtitled.
        if !didAutoSelectSubtitle, vlcSubtitleIndex < 0, let first = vlcSubtitleTracks.first {
            didAutoSelectSubtitle = true
            selectVLCSubtitle(first)
        }
    }

    /// VLC hands back two parallel arrays and includes its own "Disable" entry
    /// at index -1, which we drop in favour of our own Off button.
    private static func trackList(indexes: [Any]?, names: [Any]?) -> [PlayerTrack] {
        let numbers = (indexes as? [NSNumber]) ?? []
        let titles = (names as? [String]) ?? []
        var result: [PlayerTrack] = []
        for (offset, number) in numbers.enumerated() {
            let index = number.int32Value
            guard index >= 0 else { continue }
            let name = offset < titles.count ? titles[offset] : "Track \(index)"
            result.append(PlayerTrack(index: index, name: name))
        }
        return result
    }

    func selectVLCSubtitle(_ track: PlayerTrack?) {
        vlcPlayer.currentVideoSubTitleIndex = track?.index ?? -1
        vlcSubtitleIndex = vlcPlayer.currentVideoSubTitleIndex
        didAutoSelectSubtitle = true
        flash(track?.name ?? "Subtitles off")
    }

    func selectVLCAudio(_ track: PlayerTrack) {
        vlcPlayer.currentAudioTrackIndex = track.index
        vlcAudioIndex = vlcPlayer.currentAudioTrackIndex
        flash(track.name)
    }

    func selectAudio(_ option: AVMediaSelectionOption) { guard let group = audioGroup else { return }; player.currentItem?.select(option, in: group); flash(option.displayName) }
    func selectLegible(_ option: AVMediaSelectionOption?) { guard let group = legibleGroup else { return }; player.currentItem?.select(option, in: group); if let option { flash(option.displayName) } }
    func togglePiP() { guard media.isEngineSupported else { flash("PiP unavailable for this format"); return }; if pip == nil, AVPictureInPictureController.isPictureInPictureSupported(), let layer = layerHolder.playerLayer { pip = AVPictureInPictureController(playerLayer: layer) }; guard let pip else { flash("PiP unavailable"); return }; if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() } }
    private func periodicSave() { guard Date().timeIntervalSince(lastSave) > 4 else { return }; saveNow() }
    private func saveNow() { guard current > 0 || duration > 0 else { return }; lastSave = Date(); store.updateProgress(id: media.id, position: current, duration: duration) }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PlayerVM
    @State private var scrubValue: Double = 0
    @State private var showSubImporter = false
    @State private var dragMode: DragMode = .none
    @State private var dragStartValue: Double = 0
    @State private var seekTarget: Double = 0
    @State private var isWindowed = false

    @AppStorage("subtitleFontSize") private var subtitleFontSize = 22.0
    @AppStorage("subtitleBold") private var subtitleBold = true
    @AppStorage("subtitleBackground") private var subtitleBackground = 0.55
    private enum DragMode { case none, seek, volume, brightness }

    init(item: MediaItem, store: LibraryStore) { _vm = StateObject(wrappedValue: PlayerVM(media: item, store: store)) }

    private var subtitleTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        for ext in ["srt", "vtt"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        return types
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if vm.media.isEngineSupported { 
                    PlayerLayerView(player: vm.player, holder: vm.layerHolder, gravity: vm.fillScreen ? .resizeAspectFill : .resizeAspect).ignoresSafeArea() 
                } else { 
                    VLCPlayerLayerView(player: vm.vlcPlayer).ignoresSafeArea() 
                }

                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(count: 2, coordinateSpace: .local) { point in 
                        if point.x < geo.size.width / 2 { vm.skip(-10) } else { vm.skip(10) } 
                    }
                    .onTapGesture(count: 1) { 
                        vm.toggleControls() 
                    }
                    .gesture(panGesture(geo: geo))

                subtitleOverlay
                if let flash = vm.flashText { OSDBadge(text: flash) }

                controls
                    .opacity(vm.showControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: vm.showControls)
                    .allowsHitTesting(vm.showControls)
            }
        }
        .background(WindowChromeProbe(isWindowed: $isWindowed))
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear { vm.start(); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { vm.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .alert("Playback Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) { Button("OK") { dismiss() } } message: { Text(vm.errorMessage ?? "") }
        .fileImporter(isPresented: $showSubImporter, allowedContentTypes: subtitleTypes, allowsMultipleSelection: false) { result in if case .success(let urls) = result, let url = urls.first { vm.loadSubtitleFile(url) } }
        .preferredColorScheme(.dark)
    }

    /// Styles the external .srt overlay. VLC draws embedded subtitle tracks into
    /// the video itself, well below SwiftUI, so none of this reaches them.
    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            if vm.subtitlesOn, let cue = vm.cueText {
                Text(cue)
                    .font(.system(size: subtitleFontSize, weight: subtitleBold ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(subtitleBackground < 0.05 ? 0.9 : 0), radius: 3, y: 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(subtitleBackground), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, vm.showControls ? 140 : 44)
        .animation(.easeInOut(duration: 0.2), value: vm.showControls)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        VStack(spacing: 0) { topBar; Spacer(); centerButtons; Spacer(); bottomBar }
        .background(
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).frame(height: 130); Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 190)
            }.ignoresSafeArea().allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 40, height: 40) }
                .accessibilityLabel("Close player")

            Text(vm.media.title).font(.headline).lineLimit(1)

            Spacer()

            RoutePickerView().frame(width: 40, height: 40)
                .accessibilityLabel("AirPlay")

            Button { vm.togglePiP() } label: { Image(systemName: "pip.enter").font(.title3).frame(width: 40, height: 40) }
                .accessibilityLabel("Picture in Picture")

            trackMenu
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.leading, isWindowed ? 96 : 0)
        .animation(.easeInOut(duration: 0.2), value: isWindowed)
    }

    private var trackMenu: some View {
        Menu {
            if vm.usesVLC { vlcTrackSections } else { engineTrackSections }
        } label: { Image(systemName: "captions.bubble").font(.title3).frame(width: 40, height: 40) }
        .accessibilityLabel("Audio and subtitle tracks")
    }

    @ViewBuilder
    private var engineTrackSections: some View {
        if !vm.audioOptions.isEmpty {
            Section("Audio") { ForEach(vm.audioOptions, id: \.self) { o in Button(o.displayName) { vm.selectAudio(o) } } }
        }
        Section("Subtitles") {
            Button("Off") { vm.selectLegible(nil); vm.subtitlesOn = false }
            ForEach(vm.legibleOptions, id: \.self) { o in Button(o.displayName) { vm.selectLegible(o); vm.subtitlesOn = true } }
            subtitleFileControls
        }
    }

    @ViewBuilder
    private var vlcTrackSections: some View {
        if !vm.vlcAudioTracks.isEmpty {
            Section("Audio") {
                ForEach(vm.vlcAudioTracks) { track in
                    Button { vm.selectVLCAudio(track) } label: { trackLabel(track.name, selected: track.index == vm.vlcAudioIndex) }
                }
            }
        }
        Section("Subtitles") {
            Button { vm.selectVLCSubtitle(nil) } label: { trackLabel("Off", selected: vm.vlcSubtitleIndex < 0) }
            ForEach(vm.vlcSubtitleTracks) { track in
                Button { vm.selectVLCSubtitle(track) } label: { trackLabel(track.name, selected: track.index == vm.vlcSubtitleIndex) }
            }
            subtitleFileControls
        }
    }

    @ViewBuilder
    private func trackLabel(_ name: String, selected: Bool) -> some View {
        if selected { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    @ViewBuilder
    private var subtitleFileControls: some View {
        Button("Load .srt file…") { showSubImporter = true }
        if vm.hasExternalCues { Toggle("External subtitles", isOn: $vm.subtitlesOn) }
    }

    private var centerButtons: some View {
        HStack(spacing: 58) {
            Button { vm.skip(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                .accessibilityLabel("Skip back 10 seconds")

            Button { vm.isPlaying ? vm.pause() : vm.play() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 56)).frame(width: 84, height: 84)
            }
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")

            Button { vm.skip(10) } label: { Image(systemName: "goforward.10").font(.system(size: 34)) }
                .accessibilityLabel("Skip forward 10 seconds")
        }.foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(formatTime(vm.isScrubbing ? scrubValue : vm.current)).monospacedDigit()
                Slider(value: Binding(get: { vm.isScrubbing ? scrubValue : vm.current }, set: { scrubValue = $0 }), in: 0...max(vm.duration, 1),
                       onEditingChanged: { e in if e { scrubValue = vm.current; vm.isScrubbing = true } else { vm.isScrubbing = false; vm.seek(to: scrubValue) } }).tint(.purple)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formatTime(vm.current)) of \(formatTime(vm.duration))")
                Text(formatTime(vm.duration)).monospacedDigit()
            }.font(.footnote).foregroundStyle(.white)

            HStack(spacing: 26) {
                Menu { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button(String(format: "%.2gx", r)) { vm.setRate(r) } } } label: { Label(String(format: "%.2gx", vm.rate), systemImage: "speedometer") }
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(String(format: "%.2gx", vm.rate))

                Button { vm.fillScreen.toggle() } label: { Image(systemName: vm.fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel(vm.fillScreen ? "Fit video to screen" : "Fill screen with video")

                Spacer()
            }.font(.subheadline).foregroundStyle(.white)
         }.padding(.horizontal, 16).padding(.bottom, 14)
    }

    private func panGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                if dragMode == .none {
                    if abs(value.translation.width) > abs(value.translation.height) { dragMode = .seek; dragStartValue = vm.current; seekTarget = vm.current } 
                    else if value.startLocation.x < geo.size.width / 2 { dragMode = .brightness; dragStartValue = Double(UIScreen.main.brightness) } 
                    else { dragMode = .volume; dragStartValue = vm.volumeLevel }
                }
                switch dragMode {
                case .seek: let span = max(120, vm.duration * 0.3); let delta = Double(value.translation.width / geo.size.width) * span; seekTarget = min(max(dragStartValue + delta, 0), max(vm.duration - 1, 0)); vm.flash("\(formatTime(seekTarget))  (\(delta >= 0 ? "+" : "-")\(formatTime(abs(delta))))")
                case .volume: vm.setVolume(dragStartValue - Double(value.translation.height / 300))
                case .brightness: let level = min(max(dragStartValue - Double(value.translation.height / 300), 0), 1); UIScreen.main.brightness = CGFloat(level); vm.flash("Brightness \(Int(level * 100))%")
                case .none: break
                }
            }
            .onEnded { _ in 
                if dragMode == .seek { vm.seek(to: seekTarget) }
                dragMode = .none 
                vm.scheduleAutoHide()
            }
    }
}

struct OSDBadge: View {
    let text: String
    var body: some View { Text(text).font(.headline.monospacedDigit()).padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white) }
}

// -----------------------------------------------------------
// SUBTITLE PARSING LOGIC
// -----------------------------------------------------------

/// One embedded elementary stream reported by VLC.
struct PlayerTrack: Identifiable, Hashable {
    let index: Int32
    let name: String
    var id: Int32 { index }
}

struct SubtitleCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

enum SRTParser {
    static func parse(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let standardized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = standardized.components(separatedBy: "\n\n")
        
        for block in blocks {
            let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard lines.count >= 3 else { continue }
            
            let timeString = lines[1]
            let textLines = lines.dropFirst(2).joined(separator: "\n")
            
            let times = timeString.components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1]) else { continue }
            
            let cleanText = textLines.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            cues.append(SubtitleCue(start: start, end: end, text: cleanText))
        }
        return cues
    }

    static func cue(at time: Double, in cues: [SubtitleCue]) -> String? {
        return cues.first(where: { time >= $0.start && time <= $0.end })?.text
    }

    private static func parseTime(_ timeStr: String) -> Double? {
        let parts = timeStr.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return (h * 3600) + (m * 60) + s
    }
}
