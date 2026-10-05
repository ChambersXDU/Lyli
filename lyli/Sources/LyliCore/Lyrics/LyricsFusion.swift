import Foundation

/// Borrows word timings without replacing the official text or line boundaries.
public enum LyricsFusion {
    public static let marker = "[lyli-fusion:1]"
    public static let algorithmVersion = 1
    private static let supportedSources: Set<String> = ["kugou", "qq", "netease", "kuwo", "lrclib"]

    public struct Result: Sendable {
        public let wordTiming: String
        public let source: String
        public let matchedLines: Int
        public let totalLines: Int
    }

    public static func donorSource(in timing: String) -> String? {
        guard timing.split(separator: "\n").contains(Substring(marker)) else { return nil }
        return supportedSources.sorted().first { timing.contains("[lyli-word-source:\($0)]") }
    }

    public static func best(official: LyricsCandidate, donors: [LyricsCandidate]) -> Result? {
        donors.compactMap { fuse(official: official, donor: $0) }.sorted {
            if $0.matchedLines != $1.matchedLines { return $0.matchedLines > $1.matchedLines }
            return $0.source < $1.source
        }.first
    }

    public static func fuse(official: LyricsCandidate, donor: LyricsCandidate) -> Result? {
        guard !Task.isCancelled, official.source == "appleMusic", !official.hasWordTiming,
              supportedSources.contains(donor.source), !donor.instrumental,
              let timing = donor.wordTiming, donorSource(in: timing) == nil,
              normalized(official.title) == normalized(donor.title), !normalized(official.title).isEmpty,
              normalized(official.artist) == normalized(donor.artist), !normalized(official.artist).isEmpty,
              official.lyrics.utf8.count <= 256_000, timing.utf8.count <= 512_000 else { return nil }
        if let a = official.duration, let b = donor.duration {
            guard a.isFinite, b.isFinite, a > 0, b > 0, abs(a - b) <= 3 else { return nil }
        }
        // Different embedded offsets cannot safely share a clock.
        guard LRCParser.parseOffsetMs(official.lyrics) == LRCParser.parseOffsetMs(timing) else { return nil }
        let allBase = LRCParser.parse(official.lyrics)
        let base = allBase.filter { !normalized($0.text).isEmpty }
        let originalWords = YRCParser.parse(timing).filter { valid($0) }
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
        var rows: [String] = []
        for (i, j) in pairs {
            guard !Task.isCancelled else { return nil }
            let line = base[i]
            let boundary = allBase.first { $0.timeMs > line.timeMs }?.timeMs
                ?? official.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 21_600 ? Int($0 * 1_000) : nil }
            guard let mapped = retext(words[j].words, official: line.text), mapped.count >= 2 else { continue }
            var shifted: [LyricWord] = []
            for word in mapped {
                let start = line.timeMs + word.startMs - words[j].timeMs
                let end = start + word.durationMs
                guard start >= line.timeMs - 250,
                      boundary.map({ start < $0 && end <= $0 + 250 }) ?? true else { shifted = []; break }
                let clampedStart = max(line.timeMs, start)
                let clampedEnd = min(end, boundary ?? end)
                guard clampedEnd > clampedStart else { shifted = []; break }
                shifted.append(LyricWord(startMs: clampedStart, durationMs: clampedEnd - clampedStart, text: word.text))
            }
            guard shifted.count == mapped.count, let end = shifted.last.map({ $0.startMs + $0.durationMs }) else { continue }
            rows.append("[\(line.timeMs),\(end - line.timeMs)]" + shifted.map { "(\($0.startMs),\($0.durationMs),0)\($0.text)" }.joined())
        }
        guard rows.count >= 3, rows.count * 100 >= base.count * 55 else { return nil }
        let output = ([marker, "[lyli-word-source:\(donor.source)]"] + rows).joined(separator: "\n")
        guard LyricsMatcher.isValidWordTiming(output) else { return nil }
        return Result(wordTiming: output, source: donor.source, matchedLines: rows.count, totalLines: base.count)
    }

    private static func expanded(_ originals: [LyricLineWords], base: [LyricLine], keys: [String]) -> [LyricLineWords] {
        var result = originals
        let originalKeys = originals.map { normalized($0.words.map(\.text).joined()) }
        for i in base.indices {
            guard !Task.isCancelled else { return [] }
            let nearby = originals.indices.filter { abs(originals[$0].timeMs - base[i].timeMs) <= 2_000 }
            for j in nearby {
                // Split a donor line only at existing word boundaries, never by interpolation.
                for count in 2...3 where i + count <= base.count {
                    guard keys[i..<i + count].joined() == originalKeys[j] else { continue }
                    var cursor = 0
                    var split: [LyricLineWords] = []
                    for k in i..<i + count {
                        var chunks: [LyricWord] = []
                        var length = 0
                        while cursor < originals[j].words.count && length < keys[k].count {
                            let word = originals[j].words[cursor]
                            chunks.append(word)
                            length += normalized(word.text).count
                            cursor += 1
                        }
                        guard length == keys[k].count, let first = chunks.first else { split = []; break }
                        let start = k == i ? originals[j].timeMs : first.startMs
                        guard abs(start - base[k].timeMs) <= 2_000 else { split = []; break }
                        split.append(LyricLineWords(timeMs: start, words: chunks))
                    }
                    if split.count == count, cursor == originals[j].words.count {
                        result.append(contentsOf: split.filter { valid($0) })
                    }
                }
                // Join at most three adjacent donor rows when their complete text agrees.
                for count in 2...3 where j + count <= originals.count {
                    guard originalKeys[j..<j + count].joined() == keys[i] else { continue }
                    let row = LyricLineWords(timeMs: originals[j].timeMs,
                        words: originals[j..<j + count].flatMap(\.words))
                    if valid(row) { result.append(row) }
                }
            }
        }
        var seen: Set<String> = []
        return result.filter { seen.insert("\($0.timeMs):" + normalized($0.words.map(\.text).joined())).inserted }
            .sorted { $0.timeMs < $1.timeMs }
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

    private static func normalized(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        return (mutable as String).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
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
