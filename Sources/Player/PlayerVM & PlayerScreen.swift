// ==========================================================
//  LIQUID GLASS + SUBTITLE CONCURRENCY FIX
//
//  File:  Sources/Player/PlayerVM & PlayerScreen.swift
//  Replace the entire file.
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
    private var pendingSeekAttempts = 0
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

        let finished = media.duration > 0 && media.lastPosition >= media.duration * 0.95
        let shouldResume = autoResume && media.lastPosition > 15 && !finished

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
            case .playing: self.isPlaying = true; if let dur = self.vlcPlayer.media?.length.value?.doubleValue, dur > 0, self.duration <= 0 { self.duration = dur / 1000.0 }; self.applyPendingVLCSeek()
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
            self.applyPendingVLCSeek()
            self.updateCue(at: self.current)
            if self.duration != self.lastNowPlayingDuration { self.updateNowPlaying() }
            self.periodicSave()
            self.checkWatchedThreshold() 
        }
    }

    // MARK: - Trakt

    private var scrobbleProgress: Double {
        guard duration > 0 else { return media.progress }
        return min(max(current / duration, 0), 1)
    }

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

    private func scrobbleWatched() {
        guard !hasScrobbledWatched else { return }
        hasScrobbledWatched = true
        isScrobbling = false
        TraktService.shared.scrobble(item: media, progress: 1.0, action: .stop)
    }

    private func scrobbleAbandon() {
        guard !hasScrobbledWatched, isScrobbling else { return }
        isScrobbling = false
        TraktService.shared.scrobble(item: media, progress: scrobbleProgress, action: .stop)
    }

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

    private func updateCue(at time: Double) {
        guard subtitlesOn, hasExternalCues, !cues.isEmpty else {
            if cueText != nil { cueText = nil }
            return
        }

        while cueCursor > 0 && time < cues[cueCursor].start {
            cueCursor -= 1
        }
        while cueCursor < cues.count - 1 && time > cues[cueCursor].end {
            cueCursor += 1
        }

        let cue = cues[cueCursor]
        let text = (time >= cue.start && time <= cue.end) ? cue.text : nil
        if text != cueText { cueText = text }
    }

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
    
    func loadSubtitleFile(_ url: URL, persist: Bool = true) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { flash("Couldn't read subtitles"); return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        
        // CONCURRENCY FIX: Push the heavy parsing off the Main Actor
        Task.detached(priority: .userInitiated) {
            let parsed = SRTParser.parse(text)
            
            // Return to the Main Actor to update the UI
            await MainActor.run {
                guard !parsed.isEmpty else { self.flash("Couldn't read subtitles"); return }
                self.cues = parsed
                self.cueCursor = 0
                self.hasExternalCues = true
                self.subtitlesOn = true
                self.flash("Subtitles loaded")
            }
        }

        // CONCURRENCY FIX: Push subtitle saving off the main thread
        if persist {
            let targetURL = store.savedSubtitleURL(for: media)
            Task.detached(priority: .utility) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }
    
    private func loadSelectionGroups(for item: AVPlayerItem) { let asset = item.asset; Task { [weak self] in let chars = (try? await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)) ?? []; let audio = chars.contains(.audible) ? try? await asset.loadMediaSelectionGroup(for: .audible) : nil; let legible = chars.contains(.legible) ? try? await asset.loadMediaSelectionGroup(for: .legible) : nil; guard let self else { return }; self.audioGroup = audio; self.legibleGroup = legible; self.audioOptions = audio?.options ?? []; self.legibleOptions = legible?.options ?? [] } }
    
    private func applyPendingVLCSeek() {
        guard let target = pendingVLCSeek else { return }

        if pendingSeekAttempts > 0, abs(current - target) < 2 {
            pendingVLCSeek = nil
            pendingSeekAttempts = 0
            return
        }

        guard pendingSeekAttempts < 3 else {
            pendingVLCSeek = nil
            pendingSeekAttempts = 0
            return
        }

        pendingSeekAttempts += 1
        vlcPlayer.time = VLCTime(int: Int32(target * 1000))
        current = target
    }

    // MARK: - Lock screen, headphones and interruptions

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

    private func addCommand(_ command: MPRemoteCommand,
                            _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        remoteTargets.append((command, command.addTarget(handler: handler)))
    }

    private func observeAudioSession() {
        let notifications = NotificationCenter.default

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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
        applyPreferredChannels()
    }

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

    private func loadArtwork() async {
        let path = store.thumbURL(for: media).path
        var image: UIImage? = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value

        if image == nil, let poster = media.metadata?.posterURL,
           let (data, _)
