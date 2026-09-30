import Combine
import CoreServices
import Foundation
@testable import LyliCore

private final class ProbePosition: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

@MainActor
final class PlaybackEnergyTests {
    private func fixture() -> (LocalPlaybackSource, LyricsSyncEngine) {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
        return (LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }), engine)
    }

    func testUnchangedTicksDoNotPublish() {
        let (source, _) = fixture()
        source.updateLyrics(atMs: 2_000)
        var notifications = 0
        let subscription = source.objectWillChange.sink { notifications += 1 }
        for tick in 0..<100 { source.updateLyrics(atMs: 2_000 + tick * 5) }
        expectEqual(notifications, 0)
        expectEqual(source.currentLine?.plainText, "first")
        withExtendedLifetime(subscription) {}
    }

    func testLineBoundaryPublishesImmediately() {
        let (source, _) = fixture()
        source.updateLyrics(atMs: 4_999)
        expectEqual(source.currentLine?.plainText, "first")
        source.updateLyrics(atMs: 5_000)
        expectEqual(source.currentLine?.plainText, "second")
        expectEqual(source.currentLineIndex, 1)
        expectEqual(source.nextLineText, "third")
        source.updateLyrics(atMs: 4_999)
        expectEqual(source.currentLine?.plainText, "first")
        expectEqual(source.currentLineIndex, 0)
    }

    func testSeekUpdatesWithoutWaitingForTimer() {
        let (_, engine) = fixture()
        var targets: [Double] = []
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { targets.append($0) })
        source.seek(toMs: 2_000)
        expectEqual(source.currentLine?.plainText, "first")
        source.seek(toMs: 15_000)
        expectEqual(source.currentLine?.plainText, "third")
        expectEqual(source.pausedPositionMs, 15_000)
        source.seek(toMs: 7_000)
        expectEqual(source.currentLine?.plainText, "second")
        expectEqual(targets, [2, 15, 7])
    }

    func testOffsetCorrectionKeepsBoundaryTiming() {
        let (source, engine) = fixture()
        source.updateLyrics(atMs: 4_000)
        expectEqual(source.currentLine?.plainText, "first")
        engine.offsetMs = 1_000
        source.updateLyrics(atMs: 4_000)
        expectEqual(source.currentLine?.plainText, "second")
        engine.offsetMs = -1_000
        source.updateLyrics(atMs: 5_000)
        expectEqual(source.currentLine?.plainText, "first")
    }

    func testPlayingSeekUpdatesAnchorAndLineImmediately() {
        let (source, engine) = fixture()
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 1))
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        expectEqual(source.isPlayingNow, true)
        source.seek(toMs: 15_000)
        expectEqual(source.currentLine?.plainText, "third")
        expectEqual(source.anchor?.progressMs, 15_000)
        expectEqual(source.pausedPositionMs, nil)
        source.seek(toMs: 2_000)
        expectEqual(source.currentLine?.plainText, "first")
        expectEqual(source.anchor?.progressMs, 2_000)
    }

    func testWordFillSettlesWithoutChangingLine() {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "[00:01.00]first word\n[00:10.00]next",
                        lyricsTr: "", lyricsYRC: "[1000,2000](1000,1000,0)first (2000,1000,0)word\n[10000,1000](10000,1000,0)next")
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in })
        source.updateLyrics(atMs: 1_500)
        expectEqual(source.currentLineFillSettled, false)
        let line = source.currentLine
        source.updateLyrics(atMs: 3_500)
        expectEqual(source.currentLine, line)
        expectEqual(source.currentLineFillSettled, true)
    }

    func testClearingAndReloadingLyricsUpdatesImmediately() {
        let (source, engine) = fixture()
        source.updateLyrics(atMs: 2_000)
        _ = engine.load(lyrics: "", lyricsTr: "", lyricsYRC: "")
        source.updateLyrics(atMs: 2_000)
        expectEqual(source.currentLine, nil)
        expectEqual(source.compactLine, nil)
        expectEqual(source.currentLineIndex, nil)
        _ = engine.load(lyrics: "[00:01.00]replacement", lyricsTr: "", lyricsYRC: "")
        source.updateLyrics(atMs: 2_000)
        expectEqual(source.currentLine?.plainText, "replacement")
    }

    func testGapAndUpcomingLineUpdateWithoutActiveLineChange() {
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: "[00:01.00]first\n[00:20.00]next", lyricsTr: "",
                        lyricsYRC: "[1000,1000](1000,1000,0)first\n[20000,1000](20000,1000,0)next")
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in })
        source.updateLyrics(atMs: 1_500)
        expectEqual(source.compactLine?.plainText, "first")
        expectEqual(source.currentGapIndex, nil)
        source.updateLyrics(atMs: 5_000)
        expectEqual(source.currentLine?.plainText, "first")
        expectEqual(source.currentGapIndex, 0)
        expectEqual(source.compactShowsPlaceholder, true)
        expectEqual(source.compactLine, nil)
        source.updateLyrics(atMs: 15_000)
        expectEqual(source.currentLine?.plainText, "first")
        expectEqual(source.compactLine?.plainText, "next")
        expectEqual(source.compactShowsPlaceholder, false)
        expectEqual(source.compactLeadInMs, 5_000)
        source.updateLyrics(atMs: 20_000)
        expectEqual(source.currentLine?.plainText, "next")
        expectEqual(source.currentGapIndex, nil)
    }

    func testScheduledUpdatesMatchEveryMillisecond() {
        let fixtures: [(String, String)] = [
            ("[00:01.00]first\n[00:05.00]second\n[00:12.00]third", ""),
            ("[00:10.00]first\n[00:30.00]next\n[00:40.00]last", ""),
            ("[offset:750]\n[00:10.00]first\n[00:30.00]next\n[00:40.00]last", ""),
            ("[00:01.00]first\n[00:20.00]next", "[1000,1000](1000,1000,0)first\n[20000,1000](20000,1000,0)next"),
            ("[00:01.00]first\n[00:05.00]next\n[00:05.00]duplicate\n[00:08.00]\n[00:12.00]last",
             "[1000,6000](1000,6000,0)first\n[5000,1000](5000,1000,0)next\n[5000,2000](5000,2000,0)duplicate\n[12000,1000](12000,1000,0)last"),
        ]
        for (lrc, yrc) in fixtures {
            for offset in [-1_500, 0, 2_500] {
                let engine = LyricsSyncEngine()
                _ = engine.load(lyrics: lrc, lyricsTr: "", lyricsYRC: yrc)
                engine.offsetMs = offset
                var scheduled = engine.tickQuery(atMs: 0)
                func isSettled(_ result: LyricsSyncEngine.TickResolution, at position: Int) -> Bool {
                    result.line?.words.map {
                        position + engine.effectiveOffsetMs >= KaraokeFill.lineFillSettledMs(words: $0)
                    } ?? true
                }
                var scheduledSettled = isSettled(scheduled, at: 0)
                var next = engine.nextUpdatePositionMs(after: 0)
                var updates = 0
                for position in 0...45_000 {
                    if position == next {
                        scheduled = engine.tickQuery(atMs: position)
                        scheduledSettled = isSettled(scheduled, at: position)
                        next = engine.nextUpdatePositionMs(after: position)
                        updates += 1
                        expectEqual(next.map { $0 > position } ?? true, true)
                    }
                    let continuous = engine.tickQuery(atMs: position)
                    let settled = isSettled(continuous, at: position)
                    if continuous != scheduled || settled != scheduledSettled {
                        expectEqual(continuous, scheduled)
                        expectEqual(settled, scheduledSettled)
                        return
                    }
                }
                expectEqual(updates < 30, true)
            }
        }
    }

    func testSchedulerReplansSeekAndStopsWhenUnneeded() {
        let engine = LyricsSyncEngine()
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { nil })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 2))
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        source.setNeedsRealtimeLyricsUpdates(true)
        defer { source.stop() }
        expectEqual(abs((source.nextLyricsUpdateDate?.timeIntervalSince(source.anchor!.fetchedAt) ?? -1) - 1.5) < 0.03, true)
        source.seek(toMs: 7_000)
        expectEqual(source.currentLine?.plainText, "second")
        expectEqual(abs((source.nextLyricsUpdateDate?.timeIntervalSince(source.anchor!.fetchedAt) ?? -1) - 2.5) < 0.03, true)
        source.setScreenLocked(true)
        expectEqual(source.nextLyricsUpdateDate, nil)
        source.setScreenLocked(false)
        expectEqual(source.nextLyricsUpdateDate != nil, true)
        source.setNeedsRealtimeLyricsUpdates(false)
        expectEqual(source.nextLyricsUpdateDate, nil)
        source.setNeedsRealtimeLyricsUpdates(true)
        expectEqual(source.nextLyricsUpdateDate != nil, true)
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 7, playing: false, playbackRate: 0))
        expectEqual(source.currentLine?.plainText, "second")
        expectEqual(source.nextLyricsUpdateDate, nil)
    }

    func testScheduledTimerActuallySwitchesLine() {
        let engine = LyricsSyncEngine()
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { nil })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 0, playing: true, playbackRate: 1))
        _ = engine.load(lyrics: "[00:00.00]first\n[00:00.15]second", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        source.setNeedsRealtimeLyricsUpdates(true)
        defer { source.stop() }
        expectEqual(source.currentLine?.plainText, "first")
        let deadline = Date().addingTimeInterval(0.5)
        while source.currentLine?.plainText != "second", Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        expectEqual(source.currentLine?.plainText, "second")
        expectEqual(source.nextLyricsUpdateDate, nil)
    }

    func testPositionProbeCorrectsSmallSeekAcrossLineBoundary() {
        for playing in [true, false] {
            let engine = LyricsSyncEngine()
            let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { nil })
            source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
                album: "", duration: 60, elapsedTime: 4.95, playing: playing, playbackRate: playing ? 1 : 0))
            _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
            engine.offsetMs = 0
            source.setNeedsRealtimeLyricsUpdates(true)
            expectEqual(source.currentLine?.plainText, "first")
            source.applyPositionProbe(5)
            expectEqual(source.currentLine?.plainText, "second")
            expectEqual(source.anchor?.progressMs ?? source.pausedPositionMs, 5_000)
            source.applyPositionProbe(4.95)
            expectEqual(source.currentLine?.plainText, "first")
            expectEqual(source.anchor?.progressMs ?? source.pausedPositionMs, 4_950)
            source.stop()
        }
    }

    func testProbeTimerDetectsExternalSeekWithoutNotification() async throws {
        let engine = LyricsSyncEngine()
        let position = ProbePosition(2)
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { position.read() })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 1))
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        source.setMusicFrontmost(true)
        source.setNeedsRealtimeLyricsUpdates(true)
        defer { source.stop() }
        try await Task.sleep(nanoseconds: 30_000_000)
        position.set(15)
        let started = Date()
        while source.currentLine?.plainText != "third", Date().timeIntervalSince(started) < 0.3 {
            pumpRunLoop()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expectEqual(source.currentLine?.plainText, "third")
        expectEqual(Date().timeIntervalSince(started) < 0.3, true)
    }

    private func pumpRunLoop() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
    }

    func testStoppedSourceDiscardsInFlightProbe() async throws {
        let engine = LyricsSyncEngine()
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: {
            Thread.sleep(forTimeInterval: 0.05)
            return 7
        })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 1))
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        source.setNeedsRealtimeLyricsUpdates(true)
        source.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        expectEqual(source.currentLine?.plainText, "first")
        expectEqual(source.nextLyricsUpdateDate, nil)
        expectEqual(source.anchor?.progressMs, 2_000)
    }

    func testPositionProbeCadenceFollowsMusicActivity() {
        let engine = LyricsSyncEngine()
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { nil })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 1))
        source.setNeedsRealtimeLyricsUpdates(true)
        defer { source.stop() }
        expectEqual(source.scheduledPositionProbeInterval, 3)
        source.setMusicFrontmost(true)
        expectEqual(source.scheduledPositionProbeInterval, 0.1)
        source.setMusicFrontmost(false)
        expectEqual(source.scheduledPositionProbeInterval, 3)
        source.setScreenLocked(true)
        expectEqual(source.scheduledPositionProbeInterval, nil)
        source.setMusicFrontmost(true)
        expectEqual(source.scheduledPositionProbeInterval, nil)
        source.setScreenLocked(false)
        expectEqual(source.scheduledPositionProbeInterval, 0.1)
        source.setNeedsRealtimeLyricsUpdates(false)
        expectEqual(source.scheduledPositionProbeInterval, nil)
    }

    func testCachedMusicSamplesDoNotRepeatedlyResetClock() {
        let engine = LyricsSyncEngine()
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { nil })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 1))
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second\n[00:12.00]third", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        source.setNeedsRealtimeLyricsUpdates(true)
        defer { source.stop() }
        let initial = source.anchor!
        for elapsed in [0.1, 0.3, 0.7, 1.2] {
            source.applyPositionProbe(2, now: initial.fetchedAt.addingTimeInterval(elapsed))
            expectEqual(source.anchor?.fetchedAt, initial.fetchedAt)
        }
        source.applyPositionProbe(3.1, now: initial.fetchedAt.addingTimeInterval(1.3))
        expectEqual(source.anchor?.fetchedAt, initial.fetchedAt)
        source.applyPositionProbe(3.1, now: initial.fetchedAt.addingTimeInterval(1.6))
        expectEqual(source.anchor?.fetchedAt, initial.fetchedAt)
        source.applyPositionProbe(4.2, now: initial.fetchedAt.addingTimeInterval(2.5))
        expectEqual(source.anchor?.fetchedAt, initial.fetchedAt)
    }

    func testForwardSeekWithinSameLineCorrectsClock() {
        let engine = LyricsSyncEngine()
        let source = LocalPlaybackSource(syncEngine: engine, seekPlayer: { _ in }, positionQuery: { nil })
        source.apply(AppleMusicPlaybackSnapshot(title: "PlaybackEnergyFixture", artist: "Fixture",
            album: "", duration: 60, elapsedTime: 2, playing: true, playbackRate: 1))
        _ = engine.load(lyrics: "[00:01.00]first\n[00:05.00]second", lyricsTr: "", lyricsYRC: "")
        engine.offsetMs = 0
        source.setNeedsRealtimeLyricsUpdates(true)
        defer { source.stop() }
        let initial = source.anchor!
        source.applyPositionProbe(2.6, now: initial.fetchedAt.addingTimeInterval(0.1))
        expectEqual(source.currentLine?.plainText, "first")
        expectEqual(source.anchor?.progressMs, 2_600)
    }

    private func reply(_ value: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: 0, transactionID: AETransactionID(kAnyTransactionID))
        if let value { event.setParam(value, forKeyword: AEKeyword(keyDirectObject)) }
        return event
    }

    func testNativePositionRequestAndFractionalReply() {
        var sends = 0
        let value = AppleMusicPositionQuery.fetch(processID: 123, timeout: 5) { event, timeout in
            sends += 1
            expectEqual(event.eventClass, AEEventClass(kAECoreSuite))
            expectEqual(event.eventID, AEEventID(kAEGetData))
            expectEqual(timeout, 5)
            expectEqual(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.descriptorType,
                        DescType(typeKernelProcessID))
            let object = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
            expectEqual(object?.descriptorType, DescType(typeObjectSpecifier))
            expectEqual(object?.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue, OSType(cProperty))
            expectEqual(object?.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formPropertyID))
            expectEqual(object?.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue, OSType(0x70506F73))
            expectEqual(object?.forKeyword(AEKeyword(keyAEContainer))?.descriptorType, DescType(typeNull))
            return reply(NSAppleEventDescriptor(double: 103.75))
        }
        expectEqual(sends, 1)
        expectEqual(value, 103.75)
        var singlePrecision: Float = 103.75
        let realMusicReply = withUnsafeBytes(of: &singlePrecision) {
            NSAppleEventDescriptor(descriptorType: DescType(typeIEEE32BitFloatingPoint), data: Data($0))
        }
        expectEqual(AppleMusicPositionQuery.fetch(processID: 123, timeout: 5) { _, _ in
            reply(realMusicReply)
        }, 103.75)
        expectEqual(AppleMusicPositionQuery.fetch(processID: 123, timeout: 5) { _, _ in
            reply(NSAppleEventDescriptor(int32: 0))
        }, 0)
    }

    func testNativePositionFailuresDoNotBecomeZero() {
        for code in [errAEEventNotPermitted, errAETimeout] {
            let result = AppleMusicPositionQuery.fetch(processID: 123, timeout: 5) { _, _ in
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(code))
            }
            expectEqual(result, nil)
        }
        let errorReply = reply(NSAppleEventDescriptor(double: 20))
        errorReply.setParam(NSAppleEventDescriptor(int32: -1728), forKeyword: AEKeyword(keyErrorNumber))
        expectEqual(AppleMusicPositionQuery.fetch(processID: 123, timeout: 5) { _, _ in errorReply }, nil)
        let values: [NSAppleEventDescriptor?] = [nil, .null(), NSAppleEventDescriptor(string: "invalid"),
            NSAppleEventDescriptor(double: .nan), NSAppleEventDescriptor(double: .infinity), NSAppleEventDescriptor(double: -1)]
        for value in values {
            expectEqual(AppleMusicPositionQuery.fetch(processID: 123, timeout: 5) { _, _ in reply(value) }, nil)
        }
    }

    func testMissingMusicOrInvalidTimeoutDoesNotSend() {
        var sends = 0
        let send: AppleMusicPositionQuery.Sender = { _, _ in sends += 1; return self.reply(nil) }
        for pid: pid_t? in [nil, 0, -1] {
            expectEqual(AppleMusicPositionQuery.fetch(processID: pid, timeout: 5, send: send), nil)
        }
        for timeout in [0, -1, .infinity, .nan] {
            expectEqual(AppleMusicPositionQuery.fetch(processID: 123, timeout: timeout, send: send), nil)
        }
        expectEqual(sends, 0)
    }
}
