import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.chambersxdu.lyli", category: "local")

@MainActor
public final class LocalPlaybackSource: ObservableObject {
    public static let shared = LocalPlaybackSource()

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
    @Published public var romanizationScripts: RomanizationScripts = .default {
        didSet { reloadCurrentLyrics() }
    }
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

    private let syncEngine = LyricsSyncEngine()
    private var lastSnapshot: AppleMusicPlaybackSnapshot?
    private var lastKey = ""
    private var currentOffsetKey = ""
    private var currentPinKey = ""
    private var lastCacheVersion: Date?
    private var lastReloadSnapshot: LyricsReloadSnapshot?
    private var fastTimer: Timer?
    private var positionProbeTimer: Timer?
    private var positionProbeInFlight = false
    private var playerInfoObserver: NSObjectProtocol?
    private var screenLocked = false
    private var needsRealtimeLyricsUpdates = false
    private var menuBarPopoverIsOpen = false
    private var pollGeneration = 0
    private var settledThresholdIndex: Int?
    private var settledThresholdMs = 0

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

    private nonisolated static func shouldRunFastTimer(
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
        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    public func stop() {
        fastTimer?.invalidate(); fastTimer = nil
        positionProbeTimer?.invalidate(); positionProbeTimer = nil
        if let observer = playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        playerInfoObserver = nil
    }

    public func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        if locked {
            fastTimer?.invalidate(); fastTimer = nil
            positionProbeTimer?.invalidate(); positionProbeTimer = nil
        } else {
            updateRealtimeTimers()
            if anchor != nil { fastTick() }
        }
    }

    private func poll() {
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

    private func apply(_ snapshot: AppleMusicPlaybackSnapshot) {
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
            ensureFastTimerRunning()
        } else {
            let paused = max(0, Int((snapshot.elapsedTime ?? 0) * 1000))
            pausedPositionMs = paused
            anchor = nil
            stopFastTimer()
        }
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
            ensureFastTimerRunning()
        } else {
            stopFastTimer()
        }
    }

    private func ensurePositionProbeRunning() {
        guard lastSnapshot != nil, (!title.isEmpty || !artist.isEmpty), !screenLocked else {
            positionProbeTimer?.invalidate(); positionProbeTimer = nil
            return
        }
        guard positionProbeTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probePlayerPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionProbeTimer = timer
        probePlayerPosition()
    }

    private func probePlayerPosition() {
        guard hasRealtimeDemand, !screenLocked,
              lastSnapshot != nil, (!title.isEmpty || !artist.isEmpty),
              !positionProbeInFlight else { return }
        positionProbeInFlight = true
        let trackKey = lastKey
        Task {
            let reported = await Task.detached(priority: .utility) {
                MusicPlaybackController.fetchPlayerPosition()
            }.value
            guard self.lastKey == trackKey else {
                self.positionProbeInFlight = false
                return
            }
            self.positionProbeInFlight = false
            guard let reported, reported.isFinite, reported >= 0 else { return }
            self.applyPositionProbe(reported)
        }
    }

    private func applyPositionProbe(_ reportedSeconds: Double) {
        guard hasRealtimeDemand, !screenLocked else { return }
        let reportedMs = max(0, min(currentDurationMs ?? Int.max,
                                    Int((reportedSeconds * 1000).rounded())))
        if isPlayingNow, let current = anchor {
            let extrapolatedMs = current.extrapolatedPositionMs()
            guard abs(reportedMs - extrapolatedMs) > 1_000 else { return }
            anchor = ProgressAnchor(durationMs: current.durationMs, progressMs: reportedMs,
                                    rate: current.rate, progressTs: nil, baseAgeMs: 0,
                                    fetchedAt: Date(), fresh: true)
            fastTick()
            return
        }

        let paused = pausedPositionMs ?? -1
        guard paused < 0 || abs(reportedMs - paused) > 400 else { return }
        pausedPositionMs = reportedMs
        fastTick()
    }

    private func ensureFastTimerRunning() {
        guard Self.shouldRunFastTimer(
            isPlaying: isPlayingNow,
            hasContent: syncEngine.hasContent,
            screenLocked: screenLocked,
            needsRealtimeLyricsUpdates: hasRealtimeDemand
        ) else {
            stopFastTimer()
            return
        }
        guard fastTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func stopFastTimer() { fastTimer?.invalidate(); fastTimer = nil }

    private func clearLineDisplay() {
        currentLine = nil; nextLineText = nil; nextLineSide = nil
        currentLineIndex = nil; scrollLineIndex = nil; compactLine = nil
        compactShowsPlaceholder = false; compactDwellMs = nil; compactLeadInMs = nil
        currentGapIndex = nil; currentLineFillSettled = true; settledThresholdIndex = nil
    }

    private func fastTick() {
        guard let position = anchor?.extrapolatedPositionMs() ?? pausedPositionMs else {
            clearLineDisplay(); return
        }
        guard syncEngine.hasContent else { clearLineDisplay(); return }
        let result = syncEngine.tickQuery(atMs: position, trackEndMs: currentDurationMs)
        currentLine = result.line
        compactLine = result.compactLine
        compactShowsPlaceholder = result.compactPlaceholder
        compactDwellMs = result.compactDwellMs
        compactLeadInMs = result.compactLeadInMs
        nextLineText = result.nextText
        nextLineSide = result.nextSide
        currentLineIndex = result.index
        scrollLineIndex = result.scrollIndex
        currentGapIndex = result.gapIndex
        updateLineFillSettled(line: result.line, index: result.index, atRawMs: position)
    }

    private func updateLineFillSettled(line: SyncedLyricLine?, index: Int?, atRawMs: Int) {
        let settled: Bool
        if let words = line?.words, let index {
            if settledThresholdIndex != index {
                settledThresholdIndex = index
                settledThresholdMs = KaraokeFill.lineFillSettledMs(words: words, groups: line?.wordGroups)
            }
            settled = atRawMs + syncEngine.effectiveOffsetMs >= settledThresholdMs
        } else {
            settledThresholdIndex = nil
            settled = true
        }
        currentLineFillSettled = settled
    }

    public func forceReloadLyricsForCurrentTrack() {
        lastCacheVersion = EnrichCacheReader.contentVersion
        reloadCurrentLyrics()
        ensureFastTimerRunning()
        fastTick()
    }

    public func seek(toMs targetMs: Int) {
        let target = max(0, min(targetMs, currentDurationMs ?? targetMs))
        MusicPlaybackController.seek(toSeconds: Double(target) / 1000)
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
    }

    private struct LyricsReloadSnapshot: Equatable {
        let trackKey: String
        let lyrics, lyricsTr, lyricsRoma, lyricsYRC: String
        let instrumental, resolved, searchIncomplete: Bool
        let variant: ChineseVariant
        let romanizationScripts: RomanizationScripts
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
            lyrics: raw, lyricsTr: found?.lyricsTr ?? "", lyricsRoma: found?.lyricsRoma ?? "", lyricsYRC: found?.lyricsYRC ?? "",
            instrumental: found?.instrumental ?? false, resolved: found?.resolved ?? false,
            searchIncomplete: found?.searchIncomplete ?? false, variant: chineseVariant,
            romanizationScripts: romanizationScripts,
            plainLyrics: found?.plainLyrics ?? "")
        guard reload != lastReloadSnapshot else { return }
        lastReloadSnapshot = reload
        let japaneseSong = Romanizer.looksJapaneseSong(raw.isEmpty ? reload.lyricsYRC : raw)
        syncEngine.load(
            lyrics: chineseVariant.converted(JapaneseKanjiRepair.repair(raw, japaneseSong: japaneseSong)),
            lyricsTr: chineseVariant.converted(found?.lyricsTr ?? ""),
            lyricsRoma: found?.lyricsRoma ?? "",
            lyricsYRC: chineseVariant.converted(JapaneseKanjiRepair.repair(reload.lyricsYRC, japaneseSong: japaneseSong)),
            trackTitle: snapshot.title ?? "", trackArtist: snapshot.artist ?? "",
            romanizationScripts: romanizationScripts)
        currentOffsetKey = LyricsOffsetStore.trackKey(artist: snapshot.artist ?? "", title: snapshot.title ?? "",
                                                       lyrics: raw, lyricsYRC: reload.lyricsYRC)
        currentPinKey = EnrichCacheKeys.normalizedKey(artist: snapshot.artist ?? "", title: snapshot.title ?? "", album: snapshot.album ?? "")
        applyOffsets()
        allLines = syncEngine.allLines(idPrefix: currentOffsetKey)
        lyricsGapMarkers = syncEngine.gapMarkers()
        hasLyricsContent = syncEngine.hasContent
        isCurrentTrackInstrumental = reload.instrumental
        currentTrackHasNoLyrics = reload.resolved && !hasLyricsContent && !reload.instrumental && !reload.searchIncomplete
        currentTrackPlainLyrics = hasLyricsContent ? "" : reload.plainLyrics
    }

}
