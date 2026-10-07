import Foundation
import LyliCore

private final class FusionResolutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LyricsResolution?
    func set(_ value: LyricsResolution) { lock.lock(); stored = value; lock.unlock() }
    var value: LyricsResolution? { lock.lock(); defer { lock.unlock() }; return stored }
}

func runLiveFusionProbe() -> Never {
    let arguments = CommandLine.arguments
    let explicit = arguments.firstIndex(of: "--fusion-query").flatMap { index -> LyricsQuery? in
        guard index + 4 < arguments.count, let duration = Double(arguments[index + 4]) else { return nil }
        return LyricsQuery(title: arguments[index + 1], artist: arguments[index + 2], album: arguments[index + 3], duration: duration)
    }
    guard let query = explicit ?? MusicPlaybackController.currentLyricsQuery() else {
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
            result.set(await LyricsResolver().resolve(query, enabledIDs: ["lrclib", "kuwo", "netease", "kugou", "qq"], reference: official))
            semaphore.signal()
        }
        semaphore.wait()
        guard let resolution = result.value else { exit(1) }
        print("LIVE PROVIDERS: responded=\(resolution.sourcesResponded.joined(separator: ",")), failed=\(resolution.failures.keys.sorted().joined(separator: ",")), candidates=\(resolution.matches.count)")
        for match in resolution.matches where match.candidate.hasWordTiming {
            print("WORD CANDIDATE: source=\(match.source), title=\(match.candidate.title), artist=\(match.candidate.artist), duration=\(match.candidate.duration ?? 0), rejected=\(match.isRejected)")
        }
        if let index = arguments.firstIndex(of: "--fusion-dump"), index + 1 < arguments.count {
            func object(_ candidate: LyricsCandidate) -> [String: Any] {
                ["source": candidate.source, "title": candidate.title, "artist": candidate.artist,
                 "album": candidate.album ?? "", "duration": candidate.duration ?? 0,
                 "lyrics": candidate.lyrics, "wordTiming": candidate.wordTiming ?? ""]
            }
            let data = try JSONSerialization.data(withJSONObject: ["official": object(official),
                "donors": resolution.matches.filter { !$0.isRejected }.map { object($0.candidate) }], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: arguments[index + 1]))
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
        print("LIVE FUSION: \(query.artist) / \(query.title); sources=\(fusion.sources.joined(separator: ",")), verified=\(fusion.verifiedLines), words=\(fusion.matchedLines)/\(fusion.totalLines), official boundaries=\(correct)/\(lines.count)")
        exit(correct == lines.count ? 0 : 4)
    } catch { print(error.localizedDescription); exit(1) }
}
