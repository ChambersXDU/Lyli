import Foundation

/// A source gets one vote per line, regardless of how many search variants it returned.
enum WordTimingConsensus {
    struct Vote {
        let source: String
        let row: LyricLineWords
        let weight: Double
    }

    struct Result {
        let row: LyricLineWords
        let sources: [String]
    }

    private struct Boundary {
        let start: Int
        let end: Int
        let length: Int
    }

    private static func boundaries(_ row: LyricLineWords) -> [Int: Boundary] {
        var position = 0
        var values: [Int: Boundary] = [:]
        for word in row.words {
            let count = LyricsFusion.normalized(word.text).count
            guard count > 0 else { continue }
            values[position] = Boundary(start: word.startMs, end: word.startMs + word.durationMs, length: count)
            position += count
        }
        return values
    }

    private static func agrees(_ lhs: Vote, _ rhs: Vote) -> Bool {
        let a = boundaries(lhs.row), b = boundaries(rhs.row)
        let shared = a.keys.filter { b[$0] != nil }
        // A whole-line chunk cannot validate an otherwise detailed word trajectory.
        guard shared.count >= 2, let lastA = lhs.row.words.last, let lastB = rhs.row.words.last,
              abs(lastA.startMs + lastA.durationMs - lastB.startMs - lastB.durationMs) <= 250 else { return false }
        let errors = shared.map { abs(a[$0]!.start - b[$0]!.start) }
        return errors.allSatisfy { $0 <= 250 } && errors.reduce(0, +) <= shared.count * 150
    }

    static func resolve(_ input: [Vote]) -> Result? {
        guard !input.isEmpty else { return nil }
        // Stable ordering makes tied search variants independent of network completion order.
        let sorted = input.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.row.words.count != $1.row.words.count { return $0.row.words.count > $1.row.words.count }
            return signature($0.row) < signature($1.row)
        }
        var unique: [Vote] = []
        for group in Dictionary(grouping: sorted, by: \.source).values {
            // Pick the variant supported by the most OTHER providers; variants never vote for each other.
            let winner = group.max { a, b in
                func support(_ candidate: Vote) -> Double {
                    Dictionary(grouping: sorted.filter { $0.source != candidate.source && agrees(candidate, $0) }, by: \.source)
                        .values.reduce(0) { $0 + ($1.first?.weight ?? 0) }
                }
                let aSupport = support(a), bSupport = support(b)
                if aSupport != bSupport { return aSupport < bSupport }
                if a.row.words.count != b.row.words.count { return a.row.words.count < b.row.words.count }
                return signature(a.row) > signature(b.row)
            }
            if let winner { unique.append(winner) }
        }
        unique.sort { $0.source < $1.source }
        guard unique.count <= 5 else { return nil }
        if unique.count == 1 { return Result(row: unique[0].row, sources: [unique[0].source]) }

        // With at most five providers, enumerate mutually agreeing groups instead of allowing
        // A≈B≈C to connect A and C even when they contradict each other.
        let totalWeight = unique.reduce(0) { $0 + $1.weight }
        var best: [Vote] = []
        var bestWeight = 0.0
        var tied = false
        for mask in 1..<(1 << unique.count) {
            let group = unique.indices.filter { mask & (1 << $0) != 0 }.map { unique[$0] }
            guard group.count >= 2,
                  group.indices.allSatisfy({ i in group.indices.filter { $0 > i }.allSatisfy { agrees(group[i], group[$0]) } }) else { continue }
            let weight = group.reduce(0) { $0 + $1.weight }
            if weight > bestWeight + 1e-9 { best = group; bestWeight = weight; tied = false }
            else if abs(weight - bestWeight) <= 1e-9 { tied = true }
        }
        // An even split, or an isolated high-weight outlier, is a reason to keep line-level lyrics.
        guard !tied, bestWeight > totalWeight / 2, let reference = best.max(by: {
            if $0.row.words.count != $1.row.words.count { return $0.row.words.count < $1.row.words.count }
            return $0.source > $1.source
        }) else { return nil }
        let maps = best.map { ($0, boundaries($0.row)) }
        var position = 0
        var words: [LyricWord] = []
        for word in reference.row.words {
            let count = LyricsFusion.normalized(word.text).count
            let samples = maps.compactMap { vote, map -> (Boundary, Double)? in
                guard let boundary = map[position],
                      boundary.length == count else { return nil }
                return (boundary, vote.weight)
            }
            // Only observed matching chunks contribute: never divide a long chunk by interpolation.
            let start = median(samples.map { ($0.0.start, $0.1) }) ?? word.startMs
            let end = median(samples.map { ($0.0.end, $0.1) }) ?? (word.startMs + word.durationMs)
            guard end > start, words.last.map({ start >= $0.startMs + $0.durationMs - 80 }) ?? true else { return nil }
            words.append(LyricWord(startMs: start, durationMs: end - start, text: word.text))
            position += count
        }
        return Result(row: LyricLineWords(timeMs: reference.row.timeMs, words: words), sources: best.map(\.source))
    }

    private static func median(_ samples: [(Int, Double)]) -> Int? {
        let ordered = samples.sorted { $0.0 < $1.0 }
        let half = ordered.reduce(0) { $0 + $1.1 } / 2
        var accumulated = 0.0
        for (value, weight) in ordered {
            accumulated += weight
            if accumulated >= half { return value }
        }
        return nil
    }

    private static func signature(_ row: LyricLineWords) -> String {
        row.words.map { "\($0.startMs),\($0.durationMs),\($0.text)" }.joined(separator: "|")
    }
}
