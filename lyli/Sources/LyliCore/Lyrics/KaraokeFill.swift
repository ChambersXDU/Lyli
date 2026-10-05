import Foundation

public enum KaraokeFill {

    public static let minWordDurationMs = 80

    public static let lineTailLeadMs = 140

    public static let minTailFillMs = 120

    public static func tailClamped(_ words: [SyncedLyricWord], nextLineStartMs: Int?) -> [SyncedLyricWord] {

        guard let nextLineStartMs, let last = words.last else { return words }
        let rawDuration = max(last.durationMs, minWordDurationMs)
        let room = nextLineStartMs - lineTailLeadMs - last.startMs
        let clamped = max(min(rawDuration, room), minTailFillMs)
        guard clamped < rawDuration else { return words }
        var out = words
        out[out.count - 1] = SyncedLyricWord(text: last.text, startMs: last.startMs,
                                             durationMs: clamped)
        return out
    }

    public static let sustainedWordThresholdMs = 1_200

    public static func sustainGlowIntensity(for word: SyncedLyricWord, atMs ms: Int) -> Double {
        guard word.durationMs >= sustainedWordThresholdMs, word.durationMs <= 15_000 else { return 0 }
        let elapsed = Double(ms) - Double(word.startMs)
        let duration = Double(word.durationMs)
        guard elapsed > 0, elapsed < duration else { return 0 }
        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              text.contains(where: { $0.isLetter || $0.isNumber }) else { return 0 }
        let hasHan = text.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0x20000...0x3FFFF).contains($0.value)
        }
        if hasHan {
            guard text.filter({ $0.isLetter || $0.isNumber }).count == 1 else { return 0 }
        } else {
            guard text.count <= 24 else { return 0 }
        }
        func smooth(_ value: Double) -> Double {
            let x = min(1, max(0, value))
            return x * x * (3 - 2 * x)
        }
        let attack = smooth(elapsed / min(400, duration * 0.2))
        let release = smooth((duration - elapsed) / min(350, duration * 0.2))
        return 0.6 * attack * release * (0.7 + 0.3 * smooth(elapsed / duration))
    }

    public static let wordEdgeSoftenBand = 0.08

    public static func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        fillFraction(startMs: w.startMs, durationMs: w.durationMs, atMs: ms)
    }

    public static func fillFraction(startMs: Int, durationMs: Int, atMs ms: Int) -> Double {
        let effectiveDuration = max(durationMs, minWordDurationMs)
        return Double(ms - startMs) / Double(effectiveDuration)
    }

    public static func lineFillSettledMs(words: [SyncedLyricWord]) -> Int {
        words.reduce(0) { settled, word in
            let effective = Double(max(word.durationMs, minWordDurationMs))
            return max(settled, word.startMs + Int((effective * (1 + wordEdgeSoftenBand)).rounded(.up)))
        }
    }

    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let intensity: Double

        public init(location: Double, intensity: Double) {
            self.location = location
            self.intensity = intensity
        }
    }

    public static let allUnsungStops: [Stop] = [
        Stop(location: 0, intensity: 0), Stop(location: 1, intensity: 0),
    ]
    public static let allSungStops: [Stop] = [
        Stop(location: 0, intensity: 1), Stop(location: 1, intensity: 1),
    ]

    public static func stops(left: Double, right: Double) -> [Stop] {
        if right <= 0 { return allUnsungStops }
        if left >= 1 { return allSungStops }

        func intensity(at x: Double) -> Double {
            let t = min(1, max(0, (x - left) / (right - left)))
            return 1 - t
        }
        var result: [Stop] = []
        result.reserveCapacity(4)
        if left > 0 {
            result.append(Stop(location: 0, intensity: 1))
            result.append(Stop(location: left, intensity: 1))
        } else {
            result.append(Stop(location: 0, intensity: intensity(at: 0)))
        }
        if right < 1 {
            result.append(Stop(location: right, intensity: 0))
            result.append(Stop(location: 1, intensity: 0))
        } else {
            result.append(Stop(location: 1, intensity: intensity(at: 1)))
        }
        return result
    }
}
