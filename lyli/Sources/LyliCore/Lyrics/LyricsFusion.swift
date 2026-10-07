import Foundation

/// Aligns and cross-checks real word timings while keeping the official text and line boundaries.
public enum LyricsFusion {
    public static let marker = "[lyli-fusion:4]"
    public static let algorithmVersion = 4
    private static let supportedSources: Set<String> = ["kugou", "qq", "netease", "kuwo", "lrclib"]

    public struct Result: Sendable {
        public let wordTiming: String
        public let source: String
        public let sources: [String]
        public let verifiedLines: Int
        public let matchedLines: Int
        public let totalLines: Int
    }

    public struct Coverage: Sendable, Equatable {
        public let verifiedLines: Int
        public let matchedLines: Int
        public let totalLines: Int
        public var singleSourceLines: Int { matchedLines - verifiedLines }
    }

    public static func coverage(in timing: String) -> Coverage? {
        guard version(in: timing) != nil,
              let line = timing.split(separator: "\n").first(where: {
                  $0.hasPrefix("[lyli-word-coverage:") && $0.hasSuffix("]")
              }) else { return nil }
        let values = line.dropFirst("[lyli-word-coverage:".count).dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard values.count == 3, let verified = Int(values[0]), let matched = Int(values[1]), let total = Int(values[2]),
              (0...600).contains(total), (0...total).contains(matched), (0...matched).contains(verified) else { return nil }
        return Coverage(verifiedLines: verified, matchedLines: matched, totalLines: total)
    }

    // Apple remains the authoritative text/line clock. Equal external priors avoid claiming
    // a provider is more accurate without evidence; agreement decides their influence.
    public static let externalSourceWeights: [String: Double] = [
        "kugou": 1, "qq": 1, "netease": 1, "kuwo": 1, "lrclib": 1
    ]

    public static func version(in timing: String) -> Int? {
        timing.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("[lyli-fusion:"), line.hasSuffix("]") else { return nil }
            return Int(line.dropFirst("[lyli-fusion:".count).dropLast())
        }.first
    }

    public static func donorSources(in timing: String) -> [String] {
        guard version(in: timing) != nil else { return [] }
        let lines = timing.split(separator: "\n")
        if let line = lines.first(where: { $0.hasPrefix("[lyli-word-sources:") && $0.hasSuffix("]") }) {
            let ids = line.dropFirst("[lyli-word-sources:".count).dropLast().split(separator: ",").map(String.init)
            return Array(Set(ids).intersection(supportedSources)).sorted()
        }
        return supportedSources.sorted().filter { lines.contains(Substring("[lyli-word-source:\($0)]")) }
    }

    public static func donorSource(in timing: String) -> String? { donorSources(in: timing).first }

    private struct AlignedDonor {
        let source: String
        let rows: [LyricLineWords]
        let clockOffsetMs: Int
    }

    public static func best(official: LyricsCandidate, donors: [LyricsCandidate],
                            weights: [String: Double] = externalSourceWeights) -> Result? {
        let aligned = Set(donors).compactMap { align(official: official, donor: $0) }
        var votes: [Int: [WordTimingConsensus.Vote]] = [:]
        // Multiple album/search variants from one provider still count as one independent vote.
        for donor in aligned {
            let weight = weights[donor.source] ?? 1
            guard weight.isFinite, weight > 0 else { continue }
            for row in donor.rows {
                votes[row.timeMs, default: []].append(.init(source: donor.source, row: row, weight: min(weight, 4),
                                                          clockOffsetMs: donor.clockOffsetMs))
            }
        }
        var rows: [LyricLineWords] = []
        var sources: Set<String> = []
        var verified = 0
        for time in votes.keys.sorted() {
            guard !Task.isCancelled else { return nil }
            guard let consensus = WordTimingConsensus.resolve(votes[time] ?? []) else { continue }
            rows.append(consensus.row)
            sources.formUnion(consensus.sources)
            if consensus.sources.count > 1 { verified += 1 }
        }
        let useful = LRCParser.parse(official.lyrics).filter { LyricsMatcher.isUsefulText($0.text) && !normalized($0.text).isEmpty }
        let total = useful.count
        let totalCharacters = useful.reduce(0) { $0 + normalized($1.text).count }
        let matchedCharacters = rows.reduce(0) { $0 + normalized($1.words.map(\.text).joined()).count }
        guard rows.count >= 3, rows.count * 100 >= total * 55,
              matchedCharacters * 100 >= totalCharacters * 55 else { return nil }
        let ids = sources.sorted()
        guard let primary = ids.first else { return nil }
        let output = ([marker, "[lyli-word-sources:\(ids.joined(separator: ","))]",
                       "[lyli-word-coverage:\(verified),\(rows.count),\(total)]"] + rows.map(encode)).joined(separator: "\n")
        guard LyricsMatcher.isValidWordTiming(output) else { return nil }
        return Result(wordTiming: output, source: primary, sources: ids, verifiedLines: verified,
                      matchedLines: rows.count, totalLines: total)
    }

    public static func fuse(official: LyricsCandidate, donor: LyricsCandidate) -> Result? {
        best(official: official, donors: [donor])
    }

    private static func encode(_ row: LyricLineWords) -> String {
        let end = row.words.last.map { $0.startMs + $0.durationMs } ?? row.timeMs
        return "[\(row.timeMs),\(end - row.timeMs)]" + row.words.map {
            "(\($0.startMs),\($0.durationMs),0)\($0.text)"
        }.joined()
    }

    private static func align(official: LyricsCandidate, donor: LyricsCandidate) -> AlignedDonor? {
        guard !Task.isCancelled, official.source == "appleMusic", !official.hasWordTiming,
              supportedSources.contains(donor.source), !donor.instrumental,
              let timing = donor.wordTiming, donorSource(in: timing) == nil,
              (LyricsMatcher.hasSameTitleIdentity(official.title, donor.title)
                || LyricsCatalogIdentity.matches(title: donor.title, artist: donor.artist, album: donor.album,
                    duration: donor.duration, query: LyricsQuery(title: official.title, artist: official.artist,
                                                               album: official.album, duration: official.duration))),
              normalized(LyricsMatcher.normalizedArtist(official.artist)) == normalized(LyricsMatcher.normalizedArtist(donor.artist)),
              !normalized(official.artist).isEmpty,
              LyricsMatcher.hasSameRecordingVersion(official, donor),
              official.lyrics.utf8.count <= 256_000, timing.utf8.count <= 512_000 else { return nil }
        if let a = official.duration, let b = donor.duration {
            guard a.isFinite, b.isFinite, a > 0, b > 0, abs(a - b) <= 3 else { return nil }
        }
        // Different embedded offsets cannot safely share a clock.
        guard LRCParser.parseOffsetMs(official.lyrics) == LRCParser.parseOffsetMs(timing) else { return nil }
        let allBase = LRCParser.parse(official.lyrics).filter {
            normalized($0.text).isEmpty || LyricsMatcher.isUsefulText($0.text)
        }
        let base = allBase.filter { !normalized($0.text).isEmpty }
        let originalWords = YRCParser.parse(timing).map { row in
            LyricLineWords(timeMs: row.timeMs, words: row.words.filter { !normalized($0.text).isEmpty })
        }.filter { valid($0) && LyricsMatcher.isUsefulText($0.words.map(\.text).joined()) }
        guard (4...600).contains(base.count), (4...600).contains(originalWords.count),
              Set(base.map(\.timeMs)).count == base.count,
              Set(originalWords.map(\.timeMs)).count == originalWords.count else { return nil }
        let baseKeys = base.map { normalized($0.text) }
        let words = expanded(originalWords, base: base, keys: baseKeys)
        let wordKeys = words.map { normalized($0.words.map(\.text).joined()) }
        guard baseKeys.allSatisfy({ $0.count <= 512 }), wordKeys.allSatisfy({ $0.count <= 512 }) else { return nil }
        let baseCounts = Dictionary(baseKeys.map { ($0, 1) }, uniquingKeysWith: +)
        let wordCounts = Dictionary(wordKeys.map { ($0, 1) }, uniquingKeysWith: +)
        let anchors = baseKeys.enumerated().compactMap { i, key -> (Int, Int)? in
            guard key.count >= 3 else { return nil }
            if baseCounts[key] == 1, wordCounts[key] == 1,
               let j = wordKeys.firstIndex(of: key) { return (i, j) }
            let nearby = words.indices.filter { wordKeys[$0] == key && abs(words[$0].timeMs - base[i].timeMs) <= 2_000 }
            guard nearby.count == 1, let j = nearby.first else { return nil }
            let reverse = base.indices.filter { baseKeys[$0] == key && abs(words[j].timeMs - base[$0].timeMs) <= 2_000 }
            return reverse.count == 1 ? (i, j) : nil
        }
        guard anchors.count >= 3, Set(anchors.map { baseKeys[$0.0] }).count >= 3,
              zip(anchors, anchors.dropFirst()).allSatisfy({ words[$0.0.1].timeMs < words[$0.1.1].timeMs }),
              let first = anchors.first, let last = anchors.last,
              base[last.0].timeMs - base[first.0].timeMs >= (base.last!.timeMs - base.first!.timeMs) / 2 else { return nil }
        let deltas = anchors.map { words[$0.1].timeMs - base[$0.0].timeMs }.sorted()
        let offset = deltas[deltas.count / 2]
        guard abs(offset) <= 2_000,
              deltas.allSatisfy({ abs($0 - offset) <= 1_200 }),
              deltas.filter({ abs($0 - offset) <= 500 }).count * 5 >= deltas.count * 4 else { return nil }

        // Require exact normalized text and a unique nearby occurrence. A missing
        // chorus cannot shift the next occurrence onto an earlier official chorus.
        var pairs: [(Int, Int)] = []
        var previous = -1
        for i in base.indices {
            guard !Task.isCancelled else { return nil }
            let nearby = words.indices.filter {
                wordKeys[$0] == baseKeys[i] && abs(words[$0].timeMs - base[i].timeMs - offset) <= 650
            }
            guard nearby.count == 1, let j = nearby.first, words[j].timeMs > previous else { continue }
            let reverse = base.indices.filter {
                baseKeys[$0] == wordKeys[j] && abs(words[j].timeMs - base[$0].timeMs - offset) <= 650
            }
            guard reverse.count == 1 else { continue }
            pairs.append((i, j))
            previous = words[j].timeMs
        }
        var rows: [LyricLineWords] = []
        for (i, j) in pairs {
            guard !Task.isCancelled else { return nil }
            let line = base[i]
            let boundary = allBase.first { $0.timeMs > line.timeMs }?.timeMs
                ?? official.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 21_600 ? Int($0 * 1_000) : nil }
            guard let mapped = retext(words[j].words, official: line.text), mapped.count >= 2 else { continue }
            var shifted: [LyricWord] = []
            for word in mapped {
                // Correct one whole-song clock offset; preserve local timing instead of
                // silently snapping every source row onto the official line start.
                let start = word.startMs - offset
                let end = start + word.durationMs
                guard start >= line.timeMs - 250,
                      boundary.map({ start < $0 && end <= $0 + 250 }) ?? true else { shifted = []; break }
                let clampedStart = max(line.timeMs, start)
                let clampedEnd = min(end, boundary ?? end)
                guard clampedEnd > clampedStart else { shifted = []; break }
                shifted.append(LyricWord(startMs: clampedStart, durationMs: clampedEnd - clampedStart, text: word.text))
            }
            guard shifted.count == mapped.count else { continue }
            rows.append(LyricLineWords(timeMs: line.timeMs, words: shifted))
        }
        guard rows.count >= 3 else { return nil }
        return AlignedDonor(source: donor.source, rows: rows, clockOffsetMs: offset)
    }

    private static func expanded(_ originals: [LyricLineWords], base: [LyricLine], keys: [String]) -> [LyricLineWords] {
        let chunks = originals.map { row in row.words.map { ($0, normalized($0.text)) } }
        var result = originals
        var seen = Set(originals.map { "\($0.timeMs):" + normalized($0.words.map(\.text).joined()) })
        for i in base.indices {
            guard !Task.isCancelled else { return [] }
            // Search the real word stream, allowing crossed line breaks across at most three rows.
            // Every cut must already exist in the donor; no character timing is interpolated.
            for j in originals.indices {
                let starts = chunks[j].indices.filter {
                    !chunks[j][$0].1.isEmpty && abs(chunks[j][$0].0.startMs - base[i].timeMs) <= 2_000
                }
                guard !starts.isEmpty else { continue }
                let stream = chunks[j..<min(j + 3, chunks.count)].flatMap { $0 }
                for start in starts {
                    var key = ""
                    var words: [LyricWord] = []
                    for (word, text) in stream.dropFirst(start).prefix(512) {
                        key += text
                        words.append(word)
                        guard keys[i].hasPrefix(key) else { break }
                        if key == keys[i], let first = words.first {
                            let row = LyricLineWords(timeMs: first.startMs, words: words)
                            if valid(row), seen.insert("\(row.timeMs):" + key).inserted { result.append(row) }
                            break
                        }
                    }
                }
            }
        }
        return result.sorted { $0.timeMs < $1.timeMs }
    }

    private static func valid(_ line: LyricLineWords) -> Bool {
        guard (0..<21_600_000).contains(line.timeMs), (2...512).contains(line.words.count) else { return false }
        var previousEnd = line.timeMs - 250
        for word in line.words {
            guard (0..<21_600_000).contains(word.startMs), (1...15_000).contains(word.durationMs),
                  word.startMs >= previousEnd - 80, word.startMs >= line.timeMs - 250,
                  word.startMs + word.durationMs <= line.timeMs + 20_000 else { return false }
            previousEnd = word.startMs + word.durationMs
        }
        return true
    }

    static func normalized(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        return (mutable as String).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "妳", with: "你").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func retext(_ words: [LyricWord], official: String) -> [LyricWord]? {
        let words = words.filter { !normalized($0.text).isEmpty }
        let characters = Array(official)
        guard characters.count <= 512 else { return nil }
        let lengths = characters.map { normalized(String($0)).count }
        // Preserve the official punctuation, spacing and script at every chunk boundary.
        guard lengths.reduce(0, +) == normalized(official).count else { return nil }
        var cursor = 0
        var result: [LyricWord] = []
        for (index, word) in words.enumerated() {
            let required = normalized(word.text).count
            guard required > 0 else { return nil }
            let begin = cursor
            var consumed = 0
            while cursor < characters.count && consumed < required {
                consumed += lengths[cursor]
                cursor += 1
            }
            guard consumed == required else { return nil }
            while cursor < characters.count && lengths[cursor] == 0 { cursor += 1 }
            if index == words.count - 1, cursor != characters.count { return nil }
            result.append(LyricWord(startMs: word.startMs, durationMs: word.durationMs,
                                    text: String(characters[begin..<cursor])))
        }
        return result.map(\.text).joined() == official ? result : nil
    }
}
