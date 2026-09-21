import AppKit
import Foundation
import Combine
import LyliCore
import os

private let logger = Logger(subsystem: "com.chambersxdu.lyli", category: "coordinator")

@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let shared = PlaybackCoordinator()

    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""
    @Published private(set) var isPlayingNow: Bool = false

    @Published private(set) var isPlayingSmoothed: Bool = false

    private static let stopGracePeriod: TimeInterval = 0.25
    private var stopGraceWork: DispatchWorkItem?

    private var optimisticReconcileWork: DispatchWorkItem?
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?

    @Published private(set) var nextLineSide: LyricDuet.Side?
    @Published private(set) var hasLyricsContent: Bool = false

    @Published private(set) var isCurrentTrackInstrumental: Bool = false
    @Published private(set) var currentTrackHasNoLyrics: Bool = false

    @Published private(set) var currentTrackPlainLyrics: String = ""

    @Published private(set) var networkDown: Bool = false

    @Published private(set) var isCurrentTrackAdBreak: Bool = false

    @Published private(set) var anchor: ProgressAnchor?

    @Published private(set) var currentLineIndex: Int?

    @Published private(set) var scrollLineIndex: Int?

    @Published private(set) var compactLine: SyncedLyricLine?
    @Published private(set) var compactShowsPlaceholder: Bool = false
    @Published private(set) var compactDwellMs: Int?

    @Published private(set) var compactLeadInMs: Int?
    @Published private(set) var allLines: [MenuBarLyricLine] = []

    @Published private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published private(set) var currentGapIndex: Int?

    @Published private(set) var currentLineFillSettled: Bool = true

    @Published private(set) var currentLyricsOffsetMs: Int = 0

    @Published private(set) var trackLyricsOffsetMs: Int = 0

    @Published private(set) var pausedPositionMs: Int?
    @Published private(set) var currentDurationMs: Int?

    var compactDwellSeconds: Double? {
        if let ms = compactDwellMs, ms > 50 { return Double(ms) / 1000 }

        return currentLineDwellSeconds
    }

    var compactLeadInSeconds: Double {
        guard let ms = compactLeadInMs, ms > 0 else { return 0 }
        return Double(ms) / 1000
    }

    var currentLineDwellSeconds: Double? {
        guard let index = currentLineIndex, allLines.indices.contains(index) else { return nil }
        let startMs = allLines[index].timeMs
        let endMs: Int
        if allLines.indices.contains(index + 1) {
            endMs = allLines[index + 1].timeMs
        } else if let duration = currentDurationMs, duration > startMs {

            endMs = duration
        } else {
            return nil
        }
        let seconds = Double(endMs - startMs) / 1000

        return seconds > 0.05 ? seconds : nil
    }

    private var cancellables: [AnyCancellable] = []
    private var started = false

    private init() {}

    func refreshLyricsForCurrentTrack() {
        LocalPlaybackSource.shared.forceReloadLyricsForCurrentTrack()
    }

    func seek(toMs targetMs: Int) {
        LocalPlaybackSource.shared.seek(toMs: targetMs)
    }

    var resolvedPlayerDisplayName: String? {
        LocalPlaybackSource.shared.lastResolvedBundleID == nil ? nil : "Apple Music"
    }

    var resolvedPlayerIcon: NSImage? {
        guard LocalPlaybackSource.shared.lastResolvedBundleID != nil else { return nil }
        return AppIconResolver.icon(forBundleID: MusicPlaybackController.appleMusicBundleIdentifier)
    }

    func openResolvedPlayerApp() {
        guard LocalPlaybackSource.shared.lastResolvedBundleID != nil else {
            logger.notice("openResolvedPlayerApp: no resolved player")
            return
        }
        let bundleID = MusicPlaybackController.appleMusicBundleIdentifier
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.notice("openResolvedPlayerApp: no app for \(bundleID, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                logger.notice("openResolvedPlayerApp: \(bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                logger.notice("openResolvedPlayerApp: activated \(bundleID, privacy: .public)")
            }
        }
    }

    @discardableResult
    func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        LocalPlaybackSource.shared.nudgeLyricsOffset(by: deltaMs)
    }

    func resetLyricsOffset() {
        LocalPlaybackSource.shared.resetLyricsOffset()
    }

    func refreshLyricsOffsetForCurrentTrack() {
        LocalPlaybackSource.shared.refreshOffsetFromStore()
    }

    func setGlobalLyricsOffset(_ ms: Int) {
        LocalPlaybackSource.shared.setGlobalLyricsOffset(ms)
    }

    @Published private(set) var isFavorited: Bool?

    @Published private(set) var playbackMode: MusicPlaybackController.MusicPlaybackMode?

    private var favoritedActionSeq = 0
    private var playbackModeActionSeq = 0
    private var volumeActionSeq = 0

    @Published private(set) var soundVolume: Int?

    private var volumeWriteInFlight = false
    private var pendingVolumeTarget: Int?

    private var volumeBeforeMute: Int?

    private var isAppleMusicPlayingNow: Bool {
        LocalPlaybackSource.shared.lastResolvedBundleID == MusicPlaybackController.appleMusicBundleIdentifier
    }

    private var canRefreshAppleMusicControls: Bool {
        isAppleMusicPlayingNow && MusicAutomationPermission.check(askIfNeeded: false).isAuthorized
    }

    func refreshExtendedControls() {
        guard canRefreshAppleMusicControls else {
            if isFavorited != nil { isFavorited = nil }
            if playbackMode != nil { playbackMode = nil }
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let favSeq = favoritedActionSeq
        let modeSeq = playbackModeActionSeq
        let volSeq = volumeActionSeq
        Task.detached(priority: .utility) {
            let state = MusicPlaybackController.extendedControlsState()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.favoritedActionSeq == favSeq {
                    let value = state.favorited
                    if self.isFavorited != value { self.isFavorited = value }
                }
                if self.playbackModeActionSeq == modeSeq, self.playbackMode != state.mode {
                    self.playbackMode = state.mode
                }
                if self.volumeActionSeq == volSeq, self.soundVolume != state.volume {
                    self.soundVolume = state.volume
                }
            }
        }
    }

    func refreshFavorited() {
        guard isAppleMusicPlayingNow,
              MusicAutomationPermission.check(askIfNeeded: false).isAuthorized else {
            if isFavorited != nil { isFavorited = nil }
            return
        }
        let seq = favoritedActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.favoritedState()
            await MainActor.run { [weak self] in
                guard let self, self.favoritedActionSeq == seq else { return }
                guard self.isFavorited != value else { return }
                self.isFavorited = value
            }
        }
    }

    func refreshPlaybackMode() {
        guard canRefreshAppleMusicControls else {
            if playbackMode != nil { playbackMode = nil }
            return
        }
        let seq = playbackModeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.playbackMode()
            await MainActor.run { [weak self] in
                guard let self, self.playbackModeActionSeq == seq else { return }
                guard self.playbackMode != value else { return }
                self.playbackMode = value
            }
        }
    }

    func refreshVolume() {
        guard canRefreshAppleMusicControls else {
            if soundVolume != nil { soundVolume = nil }
            return
        }
        let seq = volumeActionSeq
        Task.detached(priority: .utility) {
            let value = MusicPlaybackController.soundVolume()
            await MainActor.run { [weak self] in
                guard let self, self.volumeActionSeq == seq else { return }
                guard self.soundVolume != value else { return }
                self.soundVolume = value
            }
        }
    }

    func setVolume(_ value: Int) {
        guard isAppleMusicPlayingNow else { return }
        let target = min(100, max(0, value))

        if soundVolume != target { soundVolume = target }
        volumeActionSeq &+= 1

        pendingVolumeTarget = target
        pumpVolumeWrite()
    }

    private func pumpVolumeWrite() {
        guard !volumeWriteInFlight, let target = pendingVolumeTarget else { return }
        pendingVolumeTarget = nil
        volumeWriteInFlight = true
        Task.detached(priority: .userInitiated) {

            let ok: Bool
            if await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                ok = false
            } else {
                ok = MusicPlaybackController.setSoundVolume(target)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.volumeWriteInFlight = false
                if self.pendingVolumeTarget != nil {

                    self.pumpVolumeWrite()
                } else if !ok {

                    self.refreshVolume()
                }
            }
        }
    }

    func toggleMute() {
        guard let current = soundVolume else { return }
        if current > 0 {
            volumeBeforeMute = current
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute ?? 50)
            volumeBeforeMute = nil
        }
    }

    func cyclePlaybackMode() {
        guard isAppleMusicPlayingNow else { return }

        let target = (playbackMode ?? .list).next()
        setPlaybackMode(target)
    }

    var playbackModeSupportsRepeatOne: Bool {
        isAppleMusicPlayingNow
    }

    func setPlaybackMode(_ target: MusicPlaybackController.MusicPlaybackMode) {
        guard isAppleMusicPlayingNow else { return }
        playbackMode = target
        playbackModeActionSeq &+= 1
        Task.detached(priority: .userInitiated) {
            if await !MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) {
                await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
                return
            }
            let wrote = MusicPlaybackController.setPlaybackMode(target)

            guard !wrote else { return }
            await MainActor.run { [weak self] in self?.refreshPlaybackMode() }
        }
    }

    func toggleFavorited() {
        guard isAppleMusicPlayingNow else { return }
        let target = !(isFavorited ?? false)
        isFavorited = target
        favoritedActionSeq &+= 1
        Task.detached(priority: .userInitiated) {

            guard await MusicAutomationPermission.checkAppleMusicSafely(askIfNeeded: true) else {
                await MainActor.run { [weak self] in self?.refreshFavorited() }
                return
            }

            guard !MusicPlaybackController.setFavorited(target) else { return }
            await MainActor.run { [weak self] in self?.refreshFavorited() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let s = LocalPlaybackSource.shared
        s.start()

        s.$title.assign(to: &$title)
        s.$artist.assign(to: &$artist)
        s.$album.assign(to: &$album)
        s.$isPlayingNow.assign(to: &$isPlayingNow)
        s.$nextLineText.assign(to: &$nextLineText)
        s.$nextLineSide.assign(to: &$nextLineSide)
        s.$anchor.assign(to: &$anchor)
        s.$hasLyricsContent.assign(to: &$hasLyricsContent)
        s.$isCurrentTrackInstrumental.assign(to: &$isCurrentTrackInstrumental)
        s.$currentTrackHasNoLyrics.assign(to: &$currentTrackHasNoLyrics)
        s.$currentTrackPlainLyrics.assign(to: &$currentTrackPlainLyrics)
        s.$networkDown.assign(to: &$networkDown)
        s.$isCurrentTrackAdBreak.assign(to: &$isCurrentTrackAdBreak)
        s.$currentLineIndex.assign(to: &$currentLineIndex)
        s.$scrollLineIndex.assign(to: &$scrollLineIndex)
        s.$compactLine.assign(to: &$compactLine)
        s.$compactShowsPlaceholder.assign(to: &$compactShowsPlaceholder)
        s.$compactDwellMs.assign(to: &$compactDwellMs)
        s.$compactLeadInMs.assign(to: &$compactLeadInMs)
        s.$allLines.assign(to: &$allLines)
        s.$lyricsGapMarkers.assign(to: &$lyricsGapMarkers)
        s.$currentGapIndex.assign(to: &$currentGapIndex)
        s.$currentLineFillSettled.assign(to: &$currentLineFillSettled)

        s.$currentLyricsOffsetMs.assign(to: &$currentLyricsOffsetMs)
        s.$trackLyricsOffsetMs.assign(to: &$trackLyricsOffsetMs)
        s.$pausedPositionMs.assign(to: &$pausedPositionMs)
        s.$currentDurationMs.assign(to: &$currentDurationMs)

        cancellables = [

            s.$title.combineLatest(s.$artist)
                .map { "\($0)|\($1)" }
                .removeDuplicates()
                .sink { [weak self] _ in

                    self?.refreshExtendedControls()
                },
            s.$isPlayingNow.sink { [weak self] playing in self?.updateSmoothedPlaying(playing) },
            s.$currentLine.sink { [weak self] line in
                logger.debug("coordinator currentLine updated: hasLine=\(line != nil) hasWords=\(line?.words != nil) hasMainText=\(line?.mainText != nil)")
                self?.currentLine = line
            },
        ]
    }

    func userTogglePlayPause() {
        MusicPlaybackController.playPause()
        stopGraceWork?.cancel()
        stopGraceWork = nil
        isPlayingSmoothed = !isPlayingNow
        optimisticReconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.optimisticReconcileWork = nil
            if self.isPlayingSmoothed != self.isPlayingNow, self.stopGraceWork == nil {
                self.isPlayingSmoothed = self.isPlayingNow
            }
        }
        optimisticReconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func updateSmoothedPlaying(_ playing: Bool) {
        stopGraceWork?.cancel()
        stopGraceWork = nil
        if playing {
            if !isPlayingSmoothed { isPlayingSmoothed = true }
            return
        }

        guard isPlayingSmoothed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopGraceWork = nil

            if !self.isPlayingNow { self.isPlayingSmoothed = false }
        }
        stopGraceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGracePeriod, execute: work)
    }
}
