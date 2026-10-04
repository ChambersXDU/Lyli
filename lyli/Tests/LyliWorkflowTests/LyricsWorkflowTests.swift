import Foundation
import LyliCore
@testable import lyli

private actor SearchGate {
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func mark() { lock.lock(); cancelled = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private struct StubProvider: LyricsProvider {
    var id = "lrclib"
    let candidates: [LyricsCandidate]
    var gate: SearchGate?
    var cancellation: CancellationFlag?
    var fails = false
    var gates: [String: SearchGate] = [:]

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        if fails { throw URLError(.notConnectedToInternet) }
        await withTaskCancellationHandler {
            await (gates[query.title] ?? gate)?.waitForRelease()
        } onCancel: {
            cancellation?.mark()
        }
        return candidates
    }
}

@MainActor
final class LyricsWorkflowTests {
    private var directory: URL!
    private var cache: EnrichCacheStore!
    private var originalEntries: [String: [String: Any]] = [:]
    private var originalSources: Set<LyricsSource> = []
    private let key = "Artist|Song|Album"
    private let originalLyrics = "[00:01.00]old verse\n[00:10.00]old chorus"
    private let editedLyrics = "[00:02.00]corrected verse\n[00:12.00]corrected chorus"
    private let yrc = "[1000,1000](1000,1000,0)old verse\n[10000,1000](10000,1000,0)old chorus"

    func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyli-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        originalEntries = EnrichCacheReader.entries
        EnrichCacheReader.entries = [:]
        originalSources = FeatureSettingsStore.shared.lyricsSources
        FeatureSettingsStore.shared.lyricsSources = [.lrclib]
        cache = EnrichCacheStore(cacheURL: directory.appendingPathComponent("cache.json"),
                                 lyricsDirectory: directory.appendingPathComponent("lyrics"),
                                 offsetsSnapshot: { [:] }, refreshPlayback: {})
    }

    func tearDown() async throws {
        EnrichCacheReader.entries = originalEntries
        FeatureSettingsStore.shared.lyricsSources = originalSources
        try FileManager.default.removeItem(at: directory)
    }

    private func service(_ provider: StubProvider) -> LyricsSearchService {
        LyricsSearchService(resolver: LyricsResolver(providers: [provider]), cache: cache)
    }

    private func timedCandidate() -> LyricsCandidate {
        LyricsCandidate(source: "lrclib", lyrics: originalLyrics, title: "Song", artist: "Artist", album: "Album")
    }

    private func searchAutomatically(_ service: LyricsSearchService) async {
        await service.searchAndSave(artist: "Artist", title: "Song", album: "Album", duration: 180)
    }

    func testInvalidWordTimingFallsBackToLyricsAndRecordsCurrentScoringVersion() async {
        let candidate = LyricsCandidate(source: "lrclib", lyrics: originalLyrics,
                                        wordTiming: "[broken]", duration: 180,
                                        title: "Song", artist: "Artist", album: "Album")
        await searchAutomatically(service(StubProvider(candidates: [candidate])))
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
        expectEqual(cache.detail(for: key).yrc, "")
        expectEqual(EnrichCacheReader.entries[key]?["lyrics_scoring_version"] as? Int,
                    LyricsMatcher.scoringVersion)
        let decision = EnrichCacheReader.entries[key]?["lyrics_decision"] as? [String: Any]
        expectEqual(decision?["scoring_version"] as? Int, LyricsMatcher.scoringVersion)
    }

    func testSameSourceTimingVariantsRemainAvailableAndBestOneIsSaved() async {
        let wrongTiming = originalLyrics.replacingOccurrences(of: "00:01", with: "00:02")
        let wrongVersion = LyricsCandidate(source: "lrclib", lyrics: wrongTiming, duration: 180,
                                           title: "Song", artist: "Artist", album: "Compilation")
        let originalVersion = LyricsCandidate(source: "lrclib", lyrics: originalLyrics, duration: 180,
                                              title: "Song", artist: "Artist", album: "Album")
        let service = service(StubProvider(candidates: [wrongVersion, originalVersion]))
        var result: LyricsSearchService.SearchUpdate?
        try? await service.search(artist: "Artist", title: "Song", album: "Album", durationSecs: 180) { result = $0 }
        expectEqual(result?.candidates.count, 2)
        expectEqual(result?.winner?.lyrics, originalLyrics)
        expectEqual(result?.winner?.id, result?.candidates.first?.id)
        await searchAutomatically(service)
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
    }

    func testAutomaticSearchSavesTimedWinnerAfterSameSourceInstrumental() async throws {
        let lateLyrics = "[00:01.00]verse\n[05:00.00]chorus"
        let timed = LyricsCandidate(source: "lrclib", lyrics: lateLyrics, duration: 360,
                                    title: "Song", artist: "Artist", album: "Album")
        let instrumental = LyricsCandidate(source: "lrclib", lyrics: "", duration: 180,
                                           title: "Song", artist: "Artist", album: "Album",
                                           instrumental: true)
        let service = service(StubProvider(candidates: [timed, instrumental]))
        var result: LyricsSearchService.SearchUpdate?
        try await service.search(artist: "Artist", title: "Song", album: "Album", durationSecs: 180) { result = $0 }
        let update = try require(result)
        let winner = try require(update.winner)
        let pick = try require(update.pick)
        expectEqual(update.candidates.first?.lyrics, "")
        expectEqual(pick.winner, "lrclib")
        expectEqual(winner.lyrics, lateLyrics)
        expectEqual(winner.id, update.candidates.last?.id)
        expectEqual(winner.score, pick.winnerScore)
        await searchAutomatically(service)
        expectEqual(cache.detail(for: key).lyrics, lateLyrics)
        expectEqual(EnrichCacheReader.entries[key]?["lyrics_score"] as? Int, pick.winnerScore)
        expectEqual(service.automaticSearchState, .completed)
    }

    func testSourcePriorityDoesNotSaveInstrumentalInsteadOfTimedWinner() async throws {
        let settings = FeatureSettingsStore.shared
        let originalMode = settings.lyricsSourceMode
        let originalOrder = settings.lyricsSourceOrder
        defer {
            settings.lyricsSourceMode = originalMode
            settings.lyricsSourceOrder = originalOrder
        }
        settings.lyricsSourceMode = .priority
        settings.lyricsSourceOrder = [.lrclib, .kuwo, .netease, .kugou, .qq]
        FeatureSettingsStore.shared.lyricsSources = [.lrclib, .kuwo]
        let instrumental = LyricsCandidate(source: "lrclib", lyrics: "", duration: 180,
                                           title: "Song", artist: "Artist", instrumental: true)
        let timed = LyricsCandidate(source: "kuwo", lyrics: originalLyrics, duration: 180,
                                    title: "Song", artist: "Artist", album: "Album")
        let service = LyricsSearchService(resolver: LyricsResolver(providers: [
            StubProvider(candidates: [instrumental]), StubProvider(id: "kuwo", candidates: [timed]),
        ]), cache: cache)
        var result: LyricsSearchService.SearchUpdate?
        try await service.search(artist: "Artist", title: "Song", album: "Album", durationSecs: 180) { result = $0 }
        let update = try require(result)
        let winner = try require(update.winner)
        expectEqual(update.candidates.first?.source, "lrclib")
        expectEqual(winner.source, "kuwo")
        expectEqual(winner.id, update.candidates.last?.id)
        await searchAutomatically(service)
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
        expectEqual(cache.summaries.first?.lyricsSource, "kuwo")
    }

    func testAutomaticResultDoesNotOverwriteManualPick() async {
        let gate = SearchGate()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        let saved = await cache.saveEdit(key: key, lyrics: editedLyrics, tr: "", yrc: "",
                                         source: "manual", markManual: true, fromManualPick: true)
        expectEqual(saved, true)
        await gate.release()
        await search.value
        expectEqual(cache.detail(for: key).lyrics, editedLyrics)
        expectEqual(EnrichCacheReader.entries[key]?["manual_lyrics"] as? Bool, true)
        expectEqual(EnrichCacheReader.entries[key]?["manual_pick_sha"] as? String,
                       ManualPickLock.fingerprint(lyrics: editedLyrics))
        let persisted = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cache.json"))) as? [String: [String: Any]]
        expectEqual(persisted?[key]?["lyrics"] as? String, editedLyrics)
    }

    func testEditingLyricsInvalidatesOldWordTimingAndDisplaysNewText() async {
        EnrichCacheReader.entries = [key: ["lyrics": originalLyrics, "lyrics_yrc": yrc]]
        let saved = await cache.saveEdit(key: key, lyrics: editedLyrics, tr: "")
        expectEqual(saved, true)
        let detail = cache.detail(for: key)
        let engine = LyricsSyncEngine()
        engine.load(lyrics: detail.lyrics, lyricsTr: detail.tr, lyricsYRC: detail.yrc)
        expectEqual(engine.activeLine(atMs: 2000)?.plainText, "corrected verse")
        expectEqual(engine.allLines(idPrefix: "test").first?.timeMs, 2000)
        expectEqual(detail.yrc, "")
    }

    func testTranslationOnlyEditPreservesWordTiming() async {
        EnrichCacheReader.entries = [key: ["lyrics": originalLyrics, "lyrics_yrc": yrc]]
        let saved = await cache.saveEdit(key: key, lyrics: originalLyrics, tr: "[00:01.00]译文")
        expectEqual(saved, true)
        expectEqual(cache.detail(for: key).yrc, yrc)
    }

    func testEmptyAutomaticSearchRecordsCompletion() async {
        await searchAutomatically(service(StubProvider(candidates: [])))
        let lyrics = EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")
        expectEqual(lyrics?.resolved, true)
        expectEqual(lyrics?.searchIncomplete, false)
        expectEqual(cache.summaries.first?.isSearching, false)
        expectEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache.json").path), true)
    }

    func testAutomaticSearchSavesPlainTextFallback() async {
        let plain = LyricsCandidate(source: "lrclib", lyrics: "Readable plain lyrics", title: "Song", artist: "Artist", plainTextOnly: true)
        await searchAutomatically(service(StubProvider(candidates: [plain])))
        let lyrics = EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")
        expectEqual(lyrics?.plainLyrics, plain.lyrics)
        expectEqual(lyrics?.resolved, true)
    }

    func testRematchCanReachFallbackForHealthyPlainTextResponse() async throws {
        let plain = LyricsCandidate(source: "lrclib", lyrics: "Plain lyrics", title: "Song", artist: "Artist", plainTextOnly: true)
        let service = service(StubProvider(candidates: [plain]))
        var result: LyricsSearchService.SearchUpdate?
        try await service.search(artist: "Artist", title: "Song", album: "Album", scope: .rematch) { result = $0 }
        let update = try require(result)
        let pick = try require(update.pick)
        expectEqual(update.winner, nil)
        expectEqual(update.networkLooksDown, false)
        expectEqual(pick.decidable, true)
        expectEqual(rematchOutcome(pick), .keptNoCandidate)
        let applied = await service.applyFallback(update, forKey: key, hasPlainTextFallback: false)
        expectEqual(applied, .plainText)
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")?.plainLyrics,
                    plain.lyrics)
    }

    func testRematchCanReachInstrumentalHandling() async throws {
        let instrumental = LyricsCandidate(source: "lrclib", lyrics: "", title: "Song", artist: "Artist", instrumental: true)
        let service = service(StubProvider(candidates: [instrumental]))
        var result: LyricsSearchService.SearchUpdate?
        try await service.search(artist: "Artist", title: "Song", album: "Album", scope: .rematch) { result = $0 }
        let update = try require(result)
        expectEqual(update.instrumental, true)
        expectEqual(update.winner, nil)
        expectEqual(rematchOutcome(try require(update.pick)), .keptNoCandidate)
        let applied = await service.applyFallback(update, forKey: key, hasPlainTextFallback: false)
        expectEqual(applied, .instrumental)
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")?.instrumental,
                    true)
    }

    func testFailedSourcesDoNotProduceANegativeMatchDecision() async throws {
        let service = service(StubProvider(candidates: [], fails: true))
        var result: LyricsSearchService.SearchUpdate?
        try await service.search(artist: "Artist", title: "Song", album: "Album", scope: .rematch) { result = $0 }
        let update = try require(result)
        expectEqual(update.networkLooksDown, true)
        expectEqual(rematchOutcome(try require(update.pick)), .keptNotDecidable)
    }

    private func rematchOutcome(_ pick: LyricsSearchService.Pick) -> LyricsRematchDecision.Outcome {
        LyricsRematchDecision.decide(decidable: pick.decidable, winnerSource: pick.winner,
                                     currentHasWordTiming: false, winnerHasWordTiming: false,
                                     sameSource: false, sameLyrics: false, sameWordTiming: false)
    }

    func testStopSearchCancelsProviderAndDiscardsLateResult() async {
        let gate = SearchGate()
        let cancellation = CancellationFlag()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate, cancellation: cancellation))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        await service.stopAutomaticSearch(forKey: key)
        await gate.release()
        await search.value
        expectEqual(cancellation.value, true)
        expectEqual(cache.detail(for: key).lyrics, "")
        expectEqual(service.automaticSearchState, .cancelled)
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")?.searchCancelled,
                    true)
        expectEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lyli-enrich-cancel-request.txt").path), false)
    }

    func testUnlockedManualPickAlsoSurvivesAutomaticSearch() async {
        let gate = SearchGate()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        let saved = await cache.saveEdit(key: key, lyrics: editedLyrics, tr: "", yrc: "",
                                         source: "manual", markManual: false, fromManualPick: true)
        expectEqual(saved, true)
        await gate.release()
        await search.value
        expectEqual(cache.detail(for: key).lyrics, editedLyrics)
    }

    func testManualPlainTextSurvivesAutomaticSearch() async {
        let gate = SearchGate()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        let saved = await cache.savePlainTextEdit(key: key, plainLyrics: "My chosen text", source: "manual")
        expectEqual(saved, true)
        await gate.release()
        await search.value
        expectEqual(cache.detail(for: key).lyrics, "")
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")?.plainLyrics,
                    "My chosen text")
    }

    func testEditingAnotherSongDoesNotDiscardAutomaticResult() async {
        let gate = SearchGate()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        let saved = await cache.saveEdit(key: "Other|Another|Album", lyrics: editedLyrics, tr: "")
        expectEqual(saved, true)
        await gate.release()
        await search.value
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
        expectEqual(cache.detail(for: "Other|Another|Album").lyrics, editedLyrics)
    }

    func testFailedAutomaticSearchCanRetryAfterNetworkRecovers() async {
        let failed = service(StubProvider(candidates: [], fails: true))
        await searchAutomatically(failed)
        let lyrics = EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")
        expectEqual(lyrics?.resolved, false)
        expectEqual(lyrics?.searchIncomplete, true)
        expectEqual(failed.automaticSearchState, .failed)
        let recovered = service(StubProvider(candidates: [timedCandidate()]))
        await searchAutomatically(recovered)
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
        expectEqual(recovered.automaticSearchState, .completed)
    }

    func testCancelledSearchCanRetryAndClearCancellation() async {
        let gate = SearchGate()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        await service.stopAutomaticSearch(forKey: key)
        await gate.release()
        await search.value
        await searchAutomatically(service)
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
        expectEqual(service.automaticSearchState, .completed)
        expectEqual(cache.searchWasCancelled(forKey: key), false)
    }

    func testStoppingDifferentSongDoesNotCancelCurrentSearch() async {
        let gate = SearchGate()
        let cancellation = CancellationFlag()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate, cancellation: cancellation))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        await service.stopAutomaticSearch(forKey: "Different|Song|Album")
        expectEqual(service.automaticSearchState, .searching)
        await gate.release()
        await search.value
        expectEqual(cancellation.value, false)
        expectEqual(cache.detail(for: key).lyrics, originalLyrics)
    }

    func testStoppingAutomaticSearchPreservesManualSearch() async {
        let automaticGate = SearchGate()
        let manualGate = SearchGate()
        let service = service(StubProvider(candidates: [timedCandidate()],
                                          gates: ["Song": automaticGate, "Manual": manualGate]))
        let automatic = Task { await searchAutomatically(service) }
        await automaticGate.waitUntilStarted()
        var manualUpdated = false
        let manual = Task {
            try await service.search(artist: "Artist", title: "Manual", album: "Album", scope: .manual) {
                _ in manualUpdated = true
            }
        }
        await manualGate.waitUntilStarted()
        await service.stopAutomaticSearch(forKey: key)
        await automaticGate.release()
        await automatic.value
        await manualGate.release()
        _ = try? await manual.value
        expectEqual(manualUpdated, true)
        expectEqual(cache.detail(for: key).lyrics, "")
    }

    func testPartialHealthyEmptySearchDoesNotStaySearching() async {
        FeatureSettingsStore.shared.lyricsSources = [.lrclib, .kuwo]
        let service = LyricsSearchService(resolver: LyricsResolver(providers: [
            StubProvider(candidates: []), StubProvider(id: "kuwo", candidates: [], fails: true),
        ]), cache: cache)
        await searchAutomatically(service)
        let lyrics = EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Album")
        expectEqual(lyrics?.resolved, true)
        expectEqual(lyrics?.searchIncomplete, false)
        expectEqual(service.automaticSearchState, .completed)
    }

    func testExplicitReplacementKeepsNewWordTiming() async {
        EnrichCacheReader.entries = [key: ["lyrics": originalLyrics, "lyrics_yrc": yrc]]
        let replacementYRC = "[2000,1000](2000,1000,0)corrected verse\n[12000,1000](12000,1000,0)corrected chorus"
        let saved = await cache.saveEdit(key: key, lyrics: editedLyrics, tr: "", yrc: replacementYRC)
        expectEqual(saved, true)
        let engine = LyricsSyncEngine()
        let detail = cache.detail(for: key)
        engine.load(lyrics: detail.lyrics, lyricsTr: detail.tr, lyricsYRC: detail.yrc)
        expectEqual(engine.activeLine(atMs: 2000)?.plainText, "corrected verse")
        expectEqual(detail.yrc, replacementYRC)
    }

    func testFailedSaveIsReportedAsFailure() async throws {
        let blockedURL = directory.appendingPathComponent("directory-instead-of-cache.json")
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)
        let failingCache = EnrichCacheStore(cacheURL: blockedURL, lyricsDirectory: directory.appendingPathComponent("lyrics"),
                                            offsetsSnapshot: { [:] }, refreshPlayback: {})
        let service = LyricsSearchService(resolver: LyricsResolver(providers: [StubProvider(candidates: [])]),
                                          cache: failingCache)
        await searchAutomatically(service)
        expectEqual(service.automaticSearchState, .failed)
        expectEqual(failingCache.lastError != nil, true)
    }

    func testSwitchingToCachedSongDiscardsPreviousAutomaticResult() async {
        let gate = SearchGate()
        let cancellation = CancellationFlag()
        let service = service(StubProvider(candidates: [timedCandidate()], gate: gate, cancellation: cancellation))
        let search = Task { await searchAutomatically(service) }
        await gate.waitUntilStarted()
        let cachedKey = "Artist|Cached|Album"
        let saved = await cache.saveEdit(key: cachedKey, lyrics: editedLyrics, tr: "")
        expectEqual(saved, true)
        await service.searchAndSave(artist: "Artist", title: "Cached", album: "Album", duration: 180)
        await gate.release()
        await search.value
        expectEqual(cancellation.value, true)
        expectEqual(cache.detail(for: key).lyrics, "")
        expectEqual(service.automaticSearchKey, cachedKey)
        expectEqual(service.automaticSearchState, .completed)
    }
}
