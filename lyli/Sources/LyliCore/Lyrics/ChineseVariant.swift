import Foundation

public enum ChineseVariant: String, CaseIterable, Sendable {
    case off, simplified, traditional

    public static func affects(_ text: String) -> Bool {
        !text.isEmpty && LyricScriptDetection.containsHan(text)
            && !LyricScriptDetection.looksJapaneseSong(text)
    }

    public func converted(_ text: String) -> String {
        guard self != .off, Self.affects(text) else { return text }
        let transform: StringTransform =
            self == .traditional
            ? StringTransform("Simplified-Traditional")
            : StringTransform("Traditional-Simplified")
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { line in
            guard !LyricScriptDetection.looksJapanese(line) else { return line }
            let icu = line.applyingTransform(transform, reverse: false) ?? line
            return self == .simplified ? HanVariants.normalizeToSimplified(icu) : icu
        }.joined(separator: "\n")
    }
}

enum LyricScriptDetection {
    private static let kanaPattern = try! NSRegularExpression(
        pattern: #"\p{Hiragana}|\p{Katakana}"#)
    private static let hanPattern = try! NSRegularExpression(pattern: #"\p{Han}"#)

    static func looksJapanese(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return kanaPattern.firstMatch(in: text, range: range) != nil
    }

    static func containsHan(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hanPattern.firstMatch(in: text, range: range) != nil
    }

    static func looksJapaneseSong(_ text: String) -> Bool {
        var total = 0
        var kana = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            total += 1
            if looksJapanese(line) { kana += 1 }
        }
        return total > 0 && Double(kana) / Double(total) >= 0.5
    }
}
