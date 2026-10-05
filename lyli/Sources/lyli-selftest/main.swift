import LyliCore
import Foundation

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

print("lyrics-parsing")
runLyricsParsingTests()

print("lyrics-resolver")
runLyricsResolverTests()
runLyricsMatcherRegressionTests()

print("cache-lookup")
runCacheLookupTests()

print("qq-music-des")
runQQMusicDESTests()

print("sync-engine")
runSyncEngineTests()

if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("FAILED (\(failures))")
    exit(1)
}
