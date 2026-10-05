import LyliCore
import Foundation

if CommandLine.arguments.contains("--glow-benchmark") { runSustainedWordGlowBenchmark(); exit(0) }

if CommandLine.arguments.contains("--fusion-live") { runLiveFusionProbe() }

if let index = CommandLine.arguments.firstIndex(of: "--fusion-cache"), index + 1 < CommandLine.arguments.count {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let entries = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
        let requested = CommandLine.arguments.last ?? ""
        var checked = 0
        var accepted = 0
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) where key.contains(requested) {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let timing = entry["lyrics_yrc"] as? String, !timing.isEmpty,
                  let source = entry["lyrics_source"] as? String, source != "appleMusic" else { continue }
            let query = LyricsQuery(title: parts[1], artist: parts[0], album: parts[2], duration: entry["resolved_duration_secs"] as? Double)
            guard let official = try AppleMusicCacheProvider().read(query).first else { continue }
            checked += 1
            let donor = LyricsCandidate(source: source, lyrics: entry["lyrics"] as? String ?? "", wordTiming: timing,
                duration: query.duration, title: query.title, artist: query.artist, album: query.album)
            guard let fusion = LyricsFusion.fuse(official: official, donor: donor) else {
                print("FUSION FALLBACK: \(parts[0]) / \(parts[1]); official retained")
                continue
            }
            let engine = LyricsSyncEngine()
            _ = engine.load(lyrics: official.lyrics, lyricsTr: official.translation ?? "", lyricsYRC: fusion.wordTiming)
            let lines = LRCParser.parse(official.lyrics).filter { !$0.text.isEmpty }
            let correct = lines.filter { engine.currentLine(at: $0.timeMs + 1)?.plainText == $0.text }.count
            let fallback = lines.filter { engine.currentLine(at: $0.timeMs + 1)?.words == nil }.count
            print("FUSION HIT: \(parts[0]) / \(parts[1]); donor=\(fusion.source), words=\(fusion.matchedLines)/\(fusion.totalLines), fallback=\(fallback), official boundaries=\(correct)/\(lines.count)")
            guard correct == lines.count else { exit(4) }
            accepted += 1
        }
        print("REAL CACHE CHECK: accepted=\(accepted), checked=\(checked)")
        exit(checked == 0 ? 3 : 0)
    } catch { print(error.localizedDescription); exit(1) }
}

if CommandLine.arguments.contains("--apple-music-cache") {
    guard let query = MusicPlaybackController.currentLyricsQuery() else {
        print("No current Music track or automation access unavailable")
        exit(2)
    }
    print("Current track: \(query.artist) / \(query.title) / \(query.album ?? "") / \(query.duration ?? 0)s")
    do {
        let candidates = try AppleMusicCacheProvider().read(query)
        guard let candidate = LyricsMatcher.rank(candidates, for: query).first(where: { !$0.isRejected })?.candidate else {
            print("CACHE MISS: no safely associated official lyrics")
            exit(3)
        }
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: candidate.lyrics, lyricsTr: candidate.translation ?? "", lyricsYRC: candidate.wordTiming ?? "")
        let lines = LRCParser.parse(candidate.lyrics).filter { !$0.text.isEmpty }
        let correct = lines.filter { engine.currentLine(at: $0.timeMs + 1)?.plainText == $0.text }.count
        print("CACHE HIT: source=\(candidate.source), lines=\(lines.count), wordLines=\(YRCParser.parse(candidate.wordTiming ?? "").count), translationLines=\(LRCParser.parse(candidate.translation ?? "").count)")
        print("SYNC CHECK: \(correct)/\(lines.count) real lyric boundaries, playerPositionAvailable=\(MusicPlaybackController.fetchPlayerPosition() != nil)")
        guard correct == lines.count else { exit(4) }
        exit(0)
    } catch { print(error.localizedDescription); exit(1) }
}

print("apple-music-cache")
runAppleMusicCacheTests()

print("lyrics-fusion")
runLyricsFusionTests()

print("lyrics-parsing")
runLyricsParsingTests()

print("lyrics-resolver")
runLyricsResolverTests()
runLyricsMatcherRegressionTests()

print("cache-lookup")
runCacheLookupTests()

print("qq-music-des")
runQQMusicDESTests()

print("sustained-word-glow")
runSustainedWordGlowTests()

print("sync-engine")
runSyncEngineTests()

if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("FAILED (\(failures))")
    exit(1)
}
