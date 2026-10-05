import Foundation

/// Keeps Apple's supplied span boundaries rather than inventing character timings.
public enum AppleMusicTTMLParser {
    public struct Result {
        public let lyrics: String
        public let translation: String?
        public let wordTiming: String?
        public let endMs: Int
    }

    public static func parse(_ xml: String, preferredLanguages: [String] = Locale.preferredLanguages) -> Result? {
        guard xml.utf8.count <= 2_000_000,
              !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid else { return nil }
        let lines = delegate.lines.sorted { $0.start < $1.start }
        guard !lines.isEmpty else { return nil }
        let lyrics = lines.enumerated().flatMap { index, line -> [String] in
            var values = [stamp(line.start) + line.text]
            if line.end > line.start, index + 1 == lines.count || line.end < lines[index + 1].start {
                values.append(stamp(line.end))
            }
            return values
        }.joined(separator: "\n")
        let words = lines.compactMap { line -> String? in
            guard line.timed, !line.parts.isEmpty else { return nil }
            let parts = line.parts.enumerated().map { index, part in
                let next = line.parts.dropFirst(index + 1).first?.start ?? line.end
                let end = part.end ?? max(part.start, next)
                return "(\(part.start),\(max(0, end - part.start)),0)\(part.text)"
            }.joined()
            return "[\(line.start),\(max(0, line.end - line.start))]" + parts
        }.joined(separator: "\n")
        let locales = delegate.translations.keys.sorted()
        let selected = preferredLanguages.lazy.compactMap { preferred in
            locales.first { language($0) == language(preferred) }
        }.first ?? locales.first
        let translated = selected.flatMap { delegate.translations[$0] } ?? [:]
        let translation = lines.compactMap { line in
            translated[line.key].map { stamp(line.start) + $0 }
        }.joined(separator: "\n")
        return Result(lyrics: lyrics, translation: translation.isEmpty ? nil : translation,
                      wordTiming: LyricsMatcher.isValidWordTiming(words) ? words : nil,
                      endMs: lines.map(\.end).max() ?? 0)
    }

    private static func language(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? value
    }

    private static func stamp(_ ms: Int) -> String {
        String(format: "[%02d:%02d.%03d]", ms / 60_000, (ms / 1000) % 60, ms % 1000)
    }

    static func milliseconds(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds: Double?
        if value.hasSuffix("ms") { seconds = Double(value.dropLast(2)).map { $0 / 1000 } }
        else if value.hasSuffix("s") { seconds = Double(value.dropLast()) }
        else {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            let numbers = fields.compactMap { Double($0) }
            guard numbers.count == fields.count, (1...3).contains(numbers.count) else { return nil }
            seconds = numbers.reduce(0) { $0 * 60 + $1 }
        }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 6 * 3600 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    private struct Part {
        var start: Int
        var end: Int?
        var text: String
    }

    private struct Line {
        let start: Int
        let end: Int
        let key: String
        var parts: [Part] = []
        var timed = false
        var text: String { parts.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var lines: [Line] = []
        var translations: [String: [String: String]] = [:]
        var invalid = false
        private var depth = 0
        private var body = false
        private var line: Line?
        private var timing: [(Int, Int?)] = []
        private var translationLanguage: String?
        private var translationKey: String?
        private var translationText = ""

        private func attribute(_ name: String, in attributes: [String: String]) -> String? {
            attributes[name] ?? attributes.first { $0.key.split(separator: ":").last == Substring(name) }?.value
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth > 64 { invalid = true; parser.abortParsing(); return }
            if name == "body" { body = true }
            if name == "translation", !body {
                translationLanguage = attribute("lang", in: attributes) ?? "und"
            }
            if name == "text", !body, translationLanguage != nil {
                translationKey = attributes["for"]; translationText = ""
            }
            if name == "p", body {
                guard let start = Self.time(attributes["begin"]),
                      let end = Self.time(attributes["end"]) ?? Self.time(attributes["dur"]).map({ start + $0 }),
                      end >= start else { line = nil; return }
                line = Line(start: start, end: end, key: attribute("key", in: attributes) ?? attribute("id", in: attributes) ?? "")
                timing = [(start, end)]
            }
            if name == "span", line != nil {
                let inherited = timing.last!
                let start = Self.time(attributes["begin"]) ?? inherited.0
                let end = Self.time(attributes["end"]) ?? Self.time(attributes["dur"]).map { start + $0 }
                    ?? (attributes["begin"] == nil ? inherited.1 : nil)
                timing.append((start, end))
                if attributes["begin"] != nil { line?.timed = true }
            }
            if name == "br", line != nil { append(" ") }
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if translationKey != nil { translationText += text }
            if line != nil { append(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1 }
            if name == "text", let key = translationKey, let locale = translationLanguage {
                translations[locale, default: [:]][key] = translationText.trimmingCharacters(in: .whitespacesAndNewlines)
                translationKey = nil
            }
            if name == "translation" { translationLanguage = nil }
            if name == "span", line != nil, timing.count > 1 { timing.removeLast() }
            if name == "p", let value = line {
                if !value.text.isEmpty { lines.append(value) }
                line = nil; timing = []
                if lines.count > 10_000 { invalid = true; parser.abortParsing() }
            }
            if name == "body" { body = false }
        }

        private static func time(_ value: String?) -> Int? { AppleMusicTTMLParser.milliseconds(value) }

        private func append(_ text: String) {
            guard !text.isEmpty, let current = timing.last, var value = line else { return }
            let whitespace = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if whitespace && value.parts.isEmpty { return }
            if let last = value.parts.last,
               whitespace || (last.start == current.0 && last.end == current.1) {
                value.parts[value.parts.count - 1].text += text
            } else {
                value.parts.append(Part(start: current.0, end: current.1, text: text))
            }
            line = value
        }
    }
}
