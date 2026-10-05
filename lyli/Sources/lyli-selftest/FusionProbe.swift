import Foundation
import LyliCore

private final class FusionResolutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LyricsResolution?
    func set(_ value: LyricsResolution) { lock.lock(); stored = value; lock.unlock() }
    var value: LyricsResolution? { lock.lock(); defer { lock.unlock() }; return stored }
}

func runLiveFusionProbe() -> Never {
    guard let query = MusicPlaybackController.currentLyricsQuery() else {
        print("No current Music track or automation access unavailable")
        exit(2)
    }
    do {
        guard let official = try AppleMusicCacheProvider().read(query).first else {
            print("OFFICIAL CACHE MISS: normal provider fallback remains available")
            exit(3)
        }
        let result = FusionResolutionBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            result.set(await LyricsResolver().resolve(query, enabledIDs: ["lrclib", "kuwo", "netease", "kugou", "qq"]))
            semaphore.signal()
        }
        semaphore.wait()
        guard let resolution = result.value else { exit(1) }
        print("LIVE PROVIDERS: responded=\(resolution.sourcesResponded.joined(separator: ",")), failed=\(resolution.failures.keys.sorted().joined(separator: ",")), candidates=\(resolution.matches.count)")
        for match in resolution.matches where match.candidate.hasWordTiming {
            print("WORD CANDIDATE: source=\(match.source), title=\(match.candidate.title), artist=\(match.candidate.artist), duration=\(match.candidate.duration ?? 0), rejected=\(match.isRejected)")
        }
        let donors = resolution.matches.filter { !$0.isRejected }.map(\.candidate)
        guard let fusion = LyricsFusion.best(official: official, donors: donors) else {
            print("FUSION FALLBACK: official lyrics retained for \(query.artist) / \(query.title)")
            exit(0)
        }
        let engine = LyricsSyncEngine()
        _ = engine.load(lyrics: official.lyrics, lyricsTr: official.translation ?? "", lyricsYRC: fusion.wordTiming)
        let lines = LRCParser.parse(official.lyrics).filter { !$0.text.isEmpty }
        let correct = lines.filter { engine.currentLine(at: $0.timeMs + 1)?.plainText == $0.text }.count
        print("LIVE FUSION: \(query.artist) / \(query.title); donor=\(fusion.source), words=\(fusion.matchedLines)/\(fusion.totalLines), official boundaries=\(correct)/\(lines.count)")
        exit(correct == lines.count ? 0 : 4)
    } catch { print(error.localizedDescription); exit(1) }
}
