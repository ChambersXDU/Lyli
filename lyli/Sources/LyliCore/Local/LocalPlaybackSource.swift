import AppKit
import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.chambersxdu.lyli", category: "local")

@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()
    private static let interactivePositionProbeInterval: TimeInterval = 0.1
    private static let backgroundPositionProbeInterval: TimeInterval = 3

    @Published public private(set) var title = ""
    @Published public private(set) var artist = ""
    @Published public private(set) var album = ""
    @Published public private(set) var isPlayingNow = false
    @Published public private(set) var currentLine: SyncedLyricLine?
    @Published public private(set) var nextLineText: String?
    @Published public private(set) var nextLineSide: LyricDuet.Side?
    @Published public private(set) var currentLineIndex: Int?
    @Published public private(set) var scrollLineIndex: Int?
    @Published public private(set) var compactLine: SyncedLyricLine?
    @Published public private(set) var compactShowsPlaceholder = false
    @Published public private(set) var compactDwellMs: Int?
    @Published public private(set) var compactLeadInMs: Int?
    @Published public private(set) var allLines: [MenuBarLyricLine] = []
    @Published public private(set) var lyricsGapMarkers: [LyricsGapMarker] = []
    @Published public private(set) var currentGapIndex: Int?
    @Published public private(set) var currentLineFillSettled = true
    @Published public private(set) var hasLyricsContent = false
    @Published public private(set) var isCurrentTrackInstrumental = false
    @Published public private(set) var currentTrackHasNoLyrics = false
    @Published public private(set) var currentTrackPlainLyrics = ""
    @Published public private(set) var networkDown = false
    @Published public private(set) var isCurrentTrackAdBreak = false
    @Published public private(set) var currentLyricsOffsetMs = 0
    @Published public private(set) var trackLyricsOffsetMs = 0
    @Published public private(set) var pausedPositionMs: Int?
    @Published public private(set) var currentDurationMs: Int?
    public var onTrackChanged: ((String, String, String, Double) -> Void)?
    @Published public var chineseVariant: ChineseVariant = .off {
        didSet { reloadCurrentLyrics() }
    }
    @Published public private(set) var sawChineseLyrics = false
    @Published public private(set) var currentLyricsSupportsChineseVariant = false
    @Published public var showsTranslation = false {
        didSet { reloadCurrentLyrics() }
    }

    @Published public private(set) var anchor: ProgressAnchor?
    @Published public private(set) var cacheContentVersion: Date?

    private let syncEngine: LyricsSyncEngine
    private let seekPlayer: @MainActor (Double) -> Void
    private let positionQuery: @Sendable () -> Double?
    private var lastSnapshot: AppleMusicPlaybackSnapshot?
    private var lastKey = ""
    private var currentOffsetKey = ""
    private var currentPinKey = ""
    private var lastCacheVersion: Date?
    private var lastReloadSnapshot: LyricsReloadSnapshot?
    private var lyricsUpdateTimer: Timer?
    private var positionProbeTimer: Timer?
    private var positionProbeInFlight = false
    private var positionProbeGeneration = 0
    private var ignorePositionProbeUntil: Date?
    private var lastPositionProbeSample: (positionMs: Int, changedAt: Date)?
    private var playerInfoObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var musicIsFrontmost = false
    private var screenLocked = false
    private var needsRealtimeLyricsUpdates = false
    private var menuBarPopoverIsOpen = false
    private var pollGeneration = 0
    private var settledThresholdIndex: Int?
    private var settledThresholdMs = 0

    init(syncEngine: LyricsSyncEngine = LyricsSyncEngine(),
         seekPlayer: @escaping @MainActor (Double) -> Void = MusicPlaybackController.seek(toSeconds:),
         positionQuery: @escaping @Sendable () -> Double? = { MusicPlaybackController.fetchPlayerPosition() }) {
        self.syncEngine = syncEngine
        self.seekPlayer = seekPlayer
        self.positionQuery = positionQuery
    }

    var nextLyricsUpdateDate: Date? { lyricsUpdateTimer?.fireDate }
    var scheduledPositionProbeInterval: TimeInterval? { positionProbeTimer?.timeInterval }

    public var lastResolvedBundleID: String? {
        lastSnapshot == nil ? nil : MusicPlaybackController.appleMusicBundleIdentifier
    }

    public func setNetworkDown(_ value: Bool) {
        networkDown = value
    }

    public func setNeedsRealtimeLyricsUpdates(_ needs: Bool) {
        needsRealtimeLyricsUpdates = needs
        updateRealtimeTimers()
    }

    public func setMenuBarPopoverOpen(_ open: Bool) {
        menuBarPopoverIsOpen = open
        updateRealtimeTimers()
    }

    private var hasRealtimeDemand: Bool {
        needsRealtimeLyricsUpdates || menuBarPopoverIsOpen
    }

    private nonisolated static func shouldScheduleLyricsUpdate(
        isPlaying: Bool, hasContent: Bool, screenLocked: Bool, needsRealtimeLyricsUpdates: Bool
    ) -> Bool {
        isPlaying && hasContent && !screenLocked && needsRealtimeLyricsUpdates
    }

    private nonisolated static func supportsChineseVariant(
        lyrics: String, translation: String, translationVisible: Bool
    ) -> Bool {
        ChineseVariant.affects(lyrics) || (translationVisible && ChineseVariant.affects(translation))
    }

    public func start() {
        guard playerInfoObserver == nil else { return }
        musicIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == MusicPlaybackController.appleMusicBundleIdentifier
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.workspaceActivationObserver != nil else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.setMusicFrontmost(application?.bundleIdentifier == MusicPlaybackController.appleMusicBundleIdentifier)
            }
        }
        poll()
    }

    public func stop() {
        pollGeneration += 1
        positionProbeGeneration += 1
        positionProbeInFlight = false
        lastPositionProbeSample = nil
        stopLyricsUpdateTimer()
        positionProbeTimer?.invalidate(); positionProbeTimer = nil
        if let observer = playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        playerInfoObserver = nil
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        workspaceActivationObserver = nil
    }

    func setMusicFrontmost(_ frontmost: Bool) {
        guard musicIsFrontmost != frontmost else { return }
        musicIsFrontmost = frontmost
        if hasRealtimeDemand { ensurePositionProbeRunning() }
    }

    public func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        if locked {
            stopLyricsUpdateTimer()
            positionProbeTimer?.invalidate(); positionProbeTimer = nil
        } else {
            updateRealtimeTimers()
        }
    }

    private func poll() {
        guard playerInfoObserver != nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        Task {
            let snapshot = await Task.detached(priority: .utility) { MusicPlaybackController.fetchSnapshot() }.value
            guard generation == pollGeneration else { return }
            guard let snapshot else {
                clearIfStopped()
                return
            }
            apply(snapshot)
        }
    }

    func apply(_ snapshot: AppleMusicPlaybackSnapshot) {
        let trackChanged = snapshot.trackKey != lastKey
        if trackChanged { networkDown = false }
        lastSnapshot = snapshot
        title = snapshot.title ?? ""
        artist = snapshot.artist ?? ""
        album = snapshot.album ?? ""
        isPlayingNow = snapshot.playing == true
        currentDurationMs = snapshot.duration.flatMap { $0 > 0 ? Int($0 * 1000) : nil }

        let version = EnrichCacheReader.contentVersion
        if cacheContentVersion != version { cacheContentVersion = version }
        if trackChanged || version != lastCacheVersion {
            lastKey = snapshot.trackKey
            lastCacheVersion = version
            reloadCurrentLyrics()
            if trackChanged, let onTrackChanged, !(snapshot.title ?? "").isEmpty, !(snapshot.artist ?? "").isEmpty {
                onTrackChanged(snapshot.artist ?? "", snapshot.title ?? "", snapshot.album ?? "", snapshot.duration ?? 0)
            }
        }

        let now = Date()
        if isPlayingNow, let duration = currentDurationMs {
            let progress = max(0, min(duration, Int((snapshot.elapsedTime ?? 0) * 1000)))
            anchor = ProgressAnchor(
                durationMs: duration, progressMs: progress, rate: max(0, snapshot.playbackRate ?? 1),
                progressTs: nil, baseAgeMs: 0, fetchedAt: now, fresh: true)
            pausedPositionMs = nil
        } else {
            let paused = max(0, Int((snapshot.elapsedTime ?? 0) * 1000))
            pausedPositionMs = paused
            anchor = nil
            stopLyricsUpdateTimer()
        }
        lastPositionProbeSample = (anchor?.progressMs ?? pausedPositionMs).map { (positionMs: $0, changedAt: now) }
        updateRealtimeTimers()
        applyOffsets()
        fastTick()
    }

    private func clearIfStopped() {
        guard !title.isEmpty || isPlayingNow else { return }
        title = ""; artist = ""; album = ""; isPlayingNow = false
        currentDurationMs = nil; pausedPositionMs = nil; anchor = nil
        clearLineDisplay()
        hasLyricsContent = false; currentTrackPlainLyrics = ""
        isCurrentTrackInstrumental = false; currentTrackHasNoLyrics = false
        lastSnapshot = nil; lastKey = ""; lastReloadSnapshot = nil
        updateRealtimeTimers()
    }

    private func updateRealtimeTimers() {
        if hasRealtimeDemand {
            ensurePositionProbeRunning()
        } else {
            positionProbeTimer?.invalidate(); positionProbeTimer = nil
        }
        if hasRealtimeDemand {
            fastTick()
        } else {
            stopLyricsUpdateTimer()
        }
    }

    private func ensurePositionProbeRunning() {
        guard lastSnapshot != nil, (!title.isEmpty || !artist.isEmpty), !screenLocked else {
            positionProbeTimer?.invalidate(); positionProbeTimer = nil
            return
        }
        let interval = musicIsFrontmost ? Self.interactivePositionProbeInterval : Self.backgroundPositionProbeInterval
        guard positionProbeTimer?.timeInterval != interval else { return }
        positionProbeTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probePlayerPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionProbeTimer = timer
        logger.debug("player position cadence changed: interval=\(interval)")
        probePlayerPosition()
    }

    private func probePlayerPosition() {
        guard hasRealtimeDemand, !screenLocked,
              lastSnapshot != nil, (!title.isEmpty || !artist.isEmpty),
              !positionProbeInFlight else { return }
        positionProbeInFlight = true
        let generation = positionProbeGeneration
        let trackKey = lastKey
        let query = positionQuery
        Task {
            let reported = await Task.detached(priority: .utility) {
                query()
            }.value
            guard generation == self.positionProbeGeneration else { return }
            logger.debug("player position probe completed: hasPosition=\(reported != nil)")
            guard self.lastKey == trackKey else {
                self.positionProbeInFlight = false
                return
            }
            self.positionProbeInFlight = false
            guard let reported, reported.isFinite, reported >= 0 else { return }
            self.applyPositionProbe(reported)
        }
    }

    func applyPositionProbe(_ reportedSeconds: Double, now: Date = Date()) {
        guard hasRealtimeDemand, !screenLocked else { return }
        if let until = ignorePositionProbeUntil {
            guard now >= until else { return }
            ignorePositionProbeUntil = nil
        }
        let reportedMs = max(0, min(currentDurationMs ?? Int.max,
                                    Int((reportedSeconds * 1000).rounded())))
        let previous = lastPositionProbeSample
        if previous?.positionMs != reportedMs {
            lastPositionProbeSample = (positionMs: reportedMs, changedAt: now)
        }
        if isPlayingNow, let current = anchor {
            // Music may return the same cached position for many consecutive reads.
            // Keep the running clock rather than repeatedly anchoring to that stale sample.
            guard previous?.positionMs != reportedMs else { return }
            let extrapolatedMs = current.extrapolatedPositionMs(now: now)
            let delta = abs(reportedMs - extrapolatedMs)
            let movedBackwards = previous.map { reportedMs < $0.positionMs - 20 } ?? false
            let jumpedForward = previous.map {
                Double(reportedMs - $0.positionMs)
                    - max(0, now.timeIntervalSince($0.changedAt)) * 1_000 * current.rate > 250
            } ?? false
            let displayAhead = reportedMs > extrapolatedMs && syncEngine.tickQuery(atMs: reportedMs, trackEndMs: currentDurationMs)
                != syncEngine.tickQuery(atMs: extrapolatedMs, trackEndMs: currentDurationMs)
            guard delta > 1_000 || movedBackwards || jumpedForward || displayAhead else { return }
            logger.debug("player position corrected: deltaMs=\(delta)")
            anchor = ProgressAnchor(durationMs: current.durationMs, progressMs: reportedMs,
                                    rate: current.rate, progressTs: nil, baseAgeMs: 0,
                                    fetchedAt: now, fresh: true)
            fastTick()
            return
        }

        let paused = pausedPositionMs ?? -1
        guard paused != reportedMs else { return }
        logger.debug("player position corrected: deltaMs=\(abs(reportedMs - paused))")
        pausedPositionMs = reportedMs
        fastTick()
    }

    private func scheduleNextLyricsUpdate(after evaluatedPosition: Int) {
        stopLyricsUpdateTimer()
        guard Self.shouldScheduleLyricsUpdate(
            isPlaying: isPlayingNow,
            hasContent: syncEngine.hasContent,
            screenLocked: screenLocked,
            needsRealtimeLyricsUpdates: hasRealtimeDemand
        ) else {
            return
        }
        guard let anchor, anchor.rate.isFinite, anchor.rate > 0 else { return }
        let now = Date()
        let position = anchor.extrapolatedPositionMs(now: now)
        guard let next = syncEngine.nextUpdatePositionMs(after: evaluatedPosition),
              next <= anchor.durationMs else { return }
        let delay = Double(next - position) / (1_000 * anchor.instantaneousRate(now: now))
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lyricsUpdateTimer = timer
    }

    private func stopLyricsUpdateTimer() { lyricsUpdateTimer?.invalidate(); lyricsUpdateTimer = nil }

    private func clearLineDisplay() {
        currentLine = nil; nextLineText = nil; nextLineSide = nil
        currentLineIndex = nil; scrollLineIndex = nil; compactLine = nil
        compactShowsPlaceholder = false; compactDwellMs = nil; compactLeadInMs = nil
        currentGapIndex = nil; currentLineFillSettled = true; settledThresholdIndex = nil
    }

    private func fastTick() {
        guard let position = anchor?.extrapolatedPositionMs() ?? pausedPositionMs else {
            clearLineDisplay(); stopLyricsUpdateTimer(); return
        }
        updateLyrics(atMs: position)
        scheduleNextLyricsUpdate(after: position)
    }

    func updateLyrics(atMs position: Int) {
        guard syncEngine.hasContent else { clearLineDisplay(); return }
        let result = syncEngine.tickQuery(atMs: position, trackEndMs: currentDurationMs)
        if currentLine != result.line { currentLine = result.line }
        if compactLine != result.compactLine { compactLine = result.compactLine }
        if compactShowsPlaceholder != result.compactPlaceholder { compactShowsPlaceholder = result.compactPlaceholder }
        if compactDwellMs != result.compactDwellMs { compactDwellMs = result.compactDwellMs }
        if compactLeadInMs != result.compactLeadInMs { compactLeadInMs = result.compactLeadInMs }
        if nextLineText != result.nextText { nextLineText = result.nextText }
        if nextLineSide != result.nextSide { nextLineSide = result.nextSide }
        if currentLineIndex != result.index { currentLineIndex = result.index }
        if scrollLineIndex != result.scrollIndex { scrollLineIndex = result.scrollIndex }
        if currentGapIndex != result.gapIndex { currentGapIndex = result.gapIndex }
        updateLineFillSettled(line: result.line, index: result.index, atRawMs: position)
    }

    private func updateLineFillSettled(line: SyncedLyricLine?, index: Int?, atRawMs: Int) {
        let settled: Bool
        if let words = line?.words, let index {
            if settledThresholdIndex != index {
                settledThresholdIndex = index
                settledThresholdMs = KaraokeFill.lineFillSettledMs(words: words)
            }
            settled = atRawMs + syncEngine.effectiveOffsetMs >= settledThresholdMs
        } else {
            settledThresholdIndex = nil
            settled = true
        }
        if currentLineFillSettled != settled { currentLineFillSettled = settled }
    }

    public func forceReloadLyricsForCurrentTrack() {
        lastCacheVersion = EnrichCacheReader.contentVersion
        reloadCurrentLyrics()
        fastTick()
    }

    public func seek(toMs targetMs: Int) {
        let target = max(0, min(targetMs, currentDurationMs ?? targetMs))
        ignorePositionProbeUntil = Date().addingTimeInterval(1)
        seekPlayer(Double(target) / 1000)
        if let current = anchor, isPlayingNow {
            anchor = ProgressAnchor(durationMs: current.durationMs, progressMs: target, rate: current.rate,
                                    progressTs: nil, baseAgeMs: 0, fetchedAt: Date(), fresh: true)
            pausedPositionMs = nil
        } else {
            pausedPositionMs = target
        }
        fastTick()
    }

    @discardableResult
    public func nudgeLyricsOffset(by deltaMs: Int) -> Int {
        guard lastSnapshot != nil else { return trackLyricsOffsetMs }
        LyricsOffsetStore.shared.nudge(by: deltaMs, forKey: currentOffsetKey, pinKey: currentPinKey)
        applyOffsets()
        return trackLyricsOffsetMs
    }

    public func resetLyricsOffset() {
        guard lastSnapshot != nil else { return }
        LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey)
        applyOffsets()
    }

    public func setGlobalLyricsOffset(_ ms: Int) {
        LyricsOffsetStore.shared.setGlobalOffset(ms)
        if lastSnapshot != nil { applyOffsets() }
    }

    public func refreshOffsetFromStore() {
        if lastSnapshot != nil { applyOffsets() }
    }

    private func applyOffsets() {
        let global = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey)
        LyricsOffsetStore.shared.syncPinToOffset(forKey: currentOffsetKey, pinKey: currentPinKey)
        let effective = LyricsOffsetStore.shared.effectiveOffset(
            forKey: currentOffsetKey, bundleID: lastResolvedBundleID)
        syncEngine.offsetMs = effective
        currentLyricsOffsetMs = effective + syncEngine.lrcOffsetMs
        trackLyricsOffsetMs = global
        fastTick()
    }

    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsYRC: String
        let instrumental, resolved, searchIncomplete, searchCancelled: Bool
        let variant: ChineseVariant
        let plainLyrics: String
    }

    private func reloadCurrentLyrics() {
        guard let snapshot = lastSnapshot else { return }
        let found = EnrichCacheReader.lookup(artist: snapshot.artist ?? "", title: snapshot.title ?? "", album: snapshot.album ?? "")
        let raw = found?.lyrics ?? ""
        if !sawChineseLyrics, ChineseVariant.affects(raw) { sawChineseLyrics = true }
        currentLyricsSupportsChineseVariant = Self.supportsChineseVariant(
            lyrics: raw, translation: found?.lyricsTr ?? "", translationVisible: showsTranslation)
        let reload = LyricsReloadSnapshot(
            trackKey: snapshot.trackKey,
            lyrics: raw, lyricsTr: found?.lyricsTr ?? "", lyricsYRC: found?.lyricsYRC ?? "",
            instrumental: found?.instrumental ?? false, resolved: found?.resolved ?? false,
            searchIncomplete: found?.searchIncomplete ?? false,
            searchCancelled: found?.searchCancelled ?? false, variant: chineseVariant,
            plainLyrics: found?.plainLyrics ?? "")
        guard reload != lastReloadSnapshot else { return }
        lastReloadSnapshot = reload
        let japaneseSong = LyricScriptDetection.looksJapaneseSong(raw.isEmpty ? reload.lyricsYRC : raw)
        syncEngine.load(
            lyrics: chineseVariant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong)),
            lyricsTr: chineseVariant.converted(found?.lyricsTr ?? ""),
            lyricsYRC: chineseVariant.converted(JapaneseKanjiRepair.repair(reload.lyricsYRC, japaneseSong: japaneseSong)),
            trackTitle: snapshot.title ?? "", trackArtist: snapshot.artist ?? "")
        settledThresholdIndex = nil
        currentOffsetKey = LyricsOffsetStore.trackKey(artist: snapshot.artist ?? "", title: snapshot.title ?? "",
                                                       lyrics: raw, lyricsYRC: reload.lyricsYRC)
        currentPinKey = EnrichCacheKeys.normalizedKey(artist: snapshot.artist ?? "", title: snapshot.title ?? "", album: snapshot.album ?? "")
        applyOffsets()
        allLines = syncEngine.allLines(idPrefix: currentOffsetKey)
        lyricsGapMarkers = syncEngine.gapMarkers()
        hasLyricsContent = syncEngine.hasContent
        isCurrentTrackInstrumental = reload.instrumental
        currentTrackHasNoLyrics = !hasLyricsContent && !reload.instrumental
            && (reload.searchCancelled || (reload.resolved && !reload.searchIncomplete))
        currentTrackPlainLyrics = hasLyricsContent ? "" : reload.plainLyrics
    }

}
