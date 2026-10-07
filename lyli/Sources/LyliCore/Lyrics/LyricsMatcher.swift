import Foundation

public struct LyricsScoreTermValue: Sendable, Equatable {
    public let kind: String
    public let points: Int

    public init(kind: String, points: Int) {
        self.kind = kind
        self.points = points
    }
}

public struct LyricsMatch: Sendable, Equatable {
    public let candidate: LyricsCandidate
    public let score: Int
    public let terms: [LyricsScoreTermValue]
    public let consensusPeers: [String]

    public var source: String { candidate.source }
    public var isRejected: Bool { terms.first?.kind.hasPrefix("reject") ?? false }

    public init(candidate: LyricsCandidate, score: Int, terms: [LyricsScoreTermValue], consensusPeers: [String] = []) {
        self.candidate = candidate
        self.score = score
        self.terms = terms
        self.consensusPeers = consensusPeers
    }
}

public enum LyricsMatcher {
    public static let scoringVersion = 23

    private static let featWords = ["feat", "ft", "featuring", "with"]
    private static let versionWords = [
        "live", "remix", "mix", "demo", "acoustic", "instrumental", "inst", "remaster", "remastered",
        "version", "edit", "extended", "radio", "karaoke", "reprise", "session", "mono",
        "stereo", "dub", "unplugged", "现场", "伴奏", "翻唱", "重制", "修复", "纯音乐",
    ]

    public static func rank(_ candidates: [LyricsCandidate], for query: LyricsQuery,
                            sourceOrder: [String] = [], prioritizeSources: Bool = false) -> [LyricsMatch] {
        let unique = deduplicate(candidates)
        guard !unique.isEmpty else { return [] }

        let firstPass = unique.map { score($0, for: query, peers: unique) }
        let usable = firstPass.filter { !$0.isRejected && !$0.candidate.instrumental }
        let bestTitle = usable.map { titleScore($0.candidate, query) }.max() ?? 0
        let bestVersion = usable.filter { titleScore($0.candidate, query) + 30 >= bestTitle }
            .map { versionMismatch($0.candidate, query) }.max() ?? 0
        let catalogAnchors = usable.filter { catalogMatch($0.candidate, query) }.map(\.candidate)
        let adjusted = firstPass.map { match -> LyricsMatch in
            guard !match.isRejected else { return match }
            let identityConflict = !catalogMatch(match.candidate, query) && catalogAnchors.contains {
                lyricsSimilarity(match.candidate.lyrics, $0.lyrics) < 0.85
            }
            let wordOverride = match.candidate.hasWordTiming && (
                titleScore(match.candidate, query) + 30 < bestTitle
                    || versionMismatch(match.candidate, query) < bestVersion || identityConflict)
            var terms = match.terms
            if wordOverride { terms.append(.init(kind: "wordTimingOverride", points: -400)) }
            if identityConflict { terms.append(.init(kind: "recordingIdentityConflict", points: -600)) }
            return LyricsMatch(candidate: match.candidate, score: match.score - (wordOverride ? 400 : 0) - (identityConflict ? 600 : 0),
                               terms: terms, consensusPeers: match.consensusPeers)
        }
        var sourceRanks: [String: Int] = [:]
        for (index, source) in sourceOrder.enumerated() where sourceRanks[source] == nil {
            sourceRanks[source] = index
        }
        return adjusted.sorted {
            if $0.isRejected != $1.isRejected { return !$0.isRejected }
            if prioritizeSources {
                let left = sourceRanks[$0.source] ?? Int.max
                let right = sourceRanks[$1.source] ?? Int.max
                if left != right { return left < right }
            }
            if $0.score != $1.score { return $0.score > $1.score }
            let left = sourceRanks[$0.source] ?? Int.max
            let right = sourceRanks[$1.source] ?? Int.max
            if left != right { return left < right }
            if $0.source != $1.source { return $0.source < $1.source }
            return stableFields($0.candidate).lexicographicallyPrecedes(stableFields($1.candidate))
        }
    }

    public static func isValidTimedLyrics(_ text: String) -> Bool {
        let lines = LRCParser.parse(text)
        guard !lines.isEmpty else { return false }
        let useful = lines.filter { isUsefulText($0.text) }
        return !useful.isEmpty && useful.count >= 2 && useful.last!.timeMs > useful.first!.timeMs
    }

    public static func isValidWordTiming(_ text: String) -> Bool {
        let useful = YRCParser.parse(text).filter { isUsefulText($0.words.map(\.text).joined()) }
        guard useful.count >= 2, let first = useful.first, let last = useful.last,
              last.timeMs > first.timeMs else { return false }
        return useful.allSatisfy { line in
            let words = line.words
            return words.allSatisfy { $0.durationMs >= 0 }
                && zip(words, words.dropFirst()).allSatisfy { $0.0.startMs <= $0.1.startMs }
        }
    }

    public static func endTime(_ candidate: LyricsCandidate) -> TimeInterval? {
        if let yrc = candidate.wordTiming,
           let last = YRCParser.parse(yrc).last(where: { isUsefulText($0.words.map(\.text).joined()) }) {
            let end = last.words.map { $0.startMs + max(0, $0.durationMs) }.max() ?? last.timeMs
            return Double(end) / 1000
        }
        guard let last = LRCParser.parse(candidate.lyrics).last(where: { isUsefulText($0.text) }) else { return nil }
        return Double(last.timeMs + LRCParser.parseOffsetMs(candidate.lyrics)) / 1000
    }

    public static func normalizedTitle(_ title: String) -> String {
        normalizeText(title).replacingOccurrences(of: "妳", with: "你")
    }

    public static func normalizedArtist(_ artist: String) -> String {
        var value = normalizeText(artist)
        for marker in featWords {
            if let range = value.range(of: " \(marker) ", options: .caseInsensitive) {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        // A mixed display name retains its complete Han name; separated collaborations remain distinct.
        if !artist.contains(where: { "/&、,，".contains($0) }),
           value.range(of: #"^[\p{Latin}\s]*([\p{Han}]{2,})[\p{Latin}\s]*$"#, options: .regularExpression) != nil {
            value = value.replacingOccurrences(of: #"[\p{Latin}\s]"#, with: "", options: .regularExpression)
        }
        return value.replacingOccurrences(of: " & ", with: " ")
    }

    private static func score(_ candidate: LyricsCandidate, for query: LyricsQuery,
                              peers: [LyricsCandidate]) -> LyricsMatch {
        var terms: [LyricsScoreTermValue] = []
        let timed = isValidTimedLyrics(candidate.lyrics)
        if candidate.plainTextOnly || (!timed && !candidate.instrumental) {
            let kind = candidate.plainTextOnly ? "rejectPlainTextOnly" : "rejectNotTimed"
            return LyricsMatch(candidate: candidate, score: -10_000,
                               terms: [.init(kind: kind, points: -10_000)])
        }
        if candidate.instrumental {
            return LyricsMatch(candidate: candidate, score: -100,
                               terms: [.init(kind: "instrumental", points: -100)])
        }

        let title = titleScore(candidate, query)
        if title == 0 {
            return LyricsMatch(candidate: candidate, score: -10_000,
                               terms: [.init(kind: "rejectWrongTitle", points: -10_000)])
        }
        if titleScore(candidate.title, query.title) == 0 {
            guard hasCrossTitleSupport(candidate, query: query, peers: peers) else {
                return LyricsMatch(candidate: candidate, score: -10_000,
                                   terms: [.init(kind: "rejectUnconfirmedIdentity", points: -10_000)])
            }
            terms.append(.init(kind: "catalogIdentity", points: 0))
        }
        terms.append(.init(kind: "titleMatch", points: title))

        let artist = artistScore(candidate.artist, query.artist)
        if artist <= 0 {
            return LyricsMatch(candidate: candidate, score: -10_000,
                               terms: [.init(kind: "rejectWrongArtist", points: -10_000)])
        }
        terms.append(.init(kind: "artistMatch", points: artist))

        let album = albumScore(candidate.album, query.album)
        if album > 0 { terms.append(.init(kind: "album", points: album)) }

        let end = endTime(candidate)
        if let duration = query.duration, duration > 0, duration.isFinite {
            if let reported = candidate.duration, reported > 0, reported.isFinite {
                let relative = abs(reported - duration) / duration
                if relative > 0.12 {
                    terms.append(.init(kind: "sourceDurationOff", points: -250))
                } else {
                    let points = abs(reported - duration) <= max(2, duration * 0.01)
                        ? 300 : max(0, 300 - Int(relative * 1500))
                    terms.append(.init(kind: "duration", points: points))
                }
            } else if let end, end <= duration + 5 {
                let relative = abs(end - duration) / duration
                terms.append(.init(kind: "lyricEnd", points: max(0, 100 - Int(relative * 200))))
            }
            if let end, end > duration + 5 {
                terms.append(.init(kind: "durationOff", points: -300))
                terms.append(.init(kind: "durationOvershoot", points: -500))
            }
        }
        let lineCount = LRCParser.parse(candidate.lyrics).filter { isUsefulText($0.text) }.count
        terms.append(.init(kind: "lines", points: min(200, lineCount)))
        if candidate.hasWordTiming { terms.append(.init(kind: "wordTiming", points: 400)) }
        if candidate.hasTranslation { terms.append(.init(kind: "translation", points: 35)) }

        let versionPenalty = versionMismatch(candidate, query)
        let peers = Set(peers.filter { other in
            versionPenalty >= 0 && other.source != candidate.source && !other.instrumental
                && (titleScore(other.title, query.title) > 0
                    || (catalogMatch(other, query) && hasCrossTitleSupport(other, query: query, peers: peers)))
                && artistScore(other.artist, query.artist) > 0
                && versionMismatch(other, query) >= 0
                && lyricsSimilarity(candidate.lyrics, other.lyrics) >= 0.72
        }.map(\.source)).sorted()
        if !peers.isEmpty {
            terms.append(.init(kind: "consensus", points: peers.count > 1 ? 250 : 150))
        }

        if versionPenalty < 0 { terms.append(.init(kind: "versionTags", points: versionPenalty)) }
        let score = terms.reduce(0) { $0 + $1.points }
        return LyricsMatch(candidate: candidate, score: score, terms: terms, consensusPeers: peers)
    }

    private static func deduplicate(_ candidates: [LyricsCandidate]) -> [LyricsCandidate] {
        var seen = Set<LyricsCandidate>()
        return candidates.filter { candidate in
            seen.insert(candidate).inserted
        }
    }

    private static func stableFields(_ candidate: LyricsCandidate) -> [String] {
        [candidate.title, candidate.artist, candidate.album ?? "", candidate.lyrics,
         candidate.wordTiming ?? "", candidate.translation ?? "", candidate.duration.map { String($0) } ?? ""]
    }

    private static func titleScore(_ candidate: LyricsCandidate, _ query: LyricsQuery) -> Int {
        let direct = titleScore(candidate.title, query.title)
        if direct > 0 { return direct }
        return catalogMatch(candidate, query) ? 80 : 0
    }

    private static func titleScore(_ candidate: String, _ query: String) -> Int {
        let a = normalizedTitle(candidate), b = normalizedTitle(query)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 120 }
        if !Set(titleAlternatives(candidate)).intersection(titleAlternatives(query)).isEmpty { return 110 }
        if normalizeText(candidate) == normalizeText(query) { return 100 }
        let core = titleCore(a)
        if !core.isEmpty && core == titleCore(b) {
            return recordingVersions(title: candidate, album: nil) == recordingVersions(title: query, album: nil)
                ? 110 : 70
        }
        if a.replacingOccurrences(of: " ", with: "") == b.replacingOccurrences(of: " ", with: "") { return 80 }
        if (" " + a + " ").contains(" " + b + " ") || (" " + b + " ").contains(" " + a + " ") { return 40 }
        if a.unicodeScalars.contains(where: { $0.value > 127 }), b.unicodeScalars.contains(where: { $0.value > 127 }),
           a.contains(b) || b.contains(a) { return 40 }
        return 0
    }

    public static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        titleScore(lhs, rhs) > 0
    }

    public static func hasSameTitleIdentity(_ lhs: String, _ rhs: String) -> Bool {
        func withoutLanguageLabel(_ text: String) -> String {
            text.replacingOccurrences(of: #"[（(](?:粤语|粵語|国语|國語)(?:版)?[）)]"#,
                                      with: "", options: .regularExpression)
        }
        return titleScore(withoutLanguageLabel(lhs), withoutLanguageLabel(rhs)) >= 80
    }

    private static func titleAlternatives(_ title: String) -> [String] {
        var names = [normalizedTitle(title)]
        guard let opening = title.firstIndex(where: { "(（[【".contains($0) }),
              let closing = title.lastIndex(where: { ")）]】".contains($0) }), opening < closing else { return names }
        let base = String(title[..<opening]).trimmingCharacters(in: .whitespaces)
        let inner = String(title[title.index(after: opening)..<closing])
        let hasHan: (String) -> Bool = { $0.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil }
        let hasLatin: (String) -> Bool = { $0.range(of: "[A-Za-z]", options: .regularExpression) != nil }
        guard !base.isEmpty, !inner.isEmpty,
              (hasHan(base) && hasLatin(inner)) || (hasLatin(base) && hasHan(inner)),
              recordingVersions(title: title, album: nil).isEmpty,
              !normalizedTitle(inner).split(separator: " ").contains(where: { isVersionToken(String($0)) }) else { return names }
        names += [normalizedTitle(base), normalizedTitle(inner)]
        return names
    }

    private static func catalogMatch(_ candidate: LyricsCandidate, _ query: LyricsQuery) -> Bool {
        LyricsCatalogIdentity.matches(title: candidate.title, artist: candidate.artist, album: candidate.album,
                                      duration: candidate.duration, query: query)
    }

    private static func hasCrossTitleSupport(_ candidate: LyricsCandidate, query: LyricsQuery,
                                            peers: [LyricsCandidate]) -> Bool {
        let eligible = peers.filter { other in
            !other.instrumental && !other.plainTextOnly && isValidTimedLyrics(other.lyrics)
                && artistScore(other.artist, query.artist) > 0 && versionMismatch(other, query) >= 0
                && (titleScore(other.title, query.title) > 0 || catalogMatch(other, query))
        }
        let body = ManualPickLock.canonicalLyrics(candidate.lyrics).filter { !$0.isWhitespace }
        guard body.count >= 40 else { return false }
        let supporting = eligible.filter { other in
            other.source != candidate.source
                && ManualPickLock.canonicalLyrics(other.lyrics).filter { !$0.isWhitespace }.count >= 40
                && lyricsSimilarity(candidate.lyrics, other.lyrics) >= 0.85
        }
        // A catalog-constrained original title can distinguish nearby album tracks.
        if supporting.contains(where: { titleScore($0.title, query.title) >= 80 && catalogMatch($0, query) }) { return true }
        let directConflicts = eligible.filter {
            catalogMatch($0, query) && titleScore($0.title, query.title) >= 80
                && lyricsSimilarity(candidate.lyrics, $0.lyrics) < 0.85
        }
        guard !directConflicts.contains(where: { $0.source == "appleMusic" }),
              Set(directConflicts.map(\.source)).count < 2 else { return false }
        guard !eligible.contains(where: { other in
            catalogMatch(other, query) && titleScore(other.title, query.title) == 0
                && normalizedTitle(other.title) != normalizedTitle(candidate.title)
                && lyricsSimilarity(candidate.lyrics, other.lyrics) < 0.85
        }) else { return false }
        return !supporting.isEmpty
    }

    private static func artistScore(_ candidate: String, _ query: String) -> Int {
        let a = normalizedArtist(candidate), b = normalizedArtist(query)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 180 }
        let candidateParts = artistParts(candidate), queryParts = artistParts(query)
        if !Set(candidateParts).intersection(queryParts).isEmpty { return 100 }
        return 0
    }

    private static func albumScore(_ candidate: String?, _ query: String?) -> Int {
        guard let candidate, let query, !candidate.isEmpty, !query.isEmpty else { return 0 }
        let a = normalizeText(candidate), b = normalizeText(query)
        return a == b ? 100 : ((a.contains(b) || b.contains(a)) ? 40 : 0)
    }

    private static func versionMismatch(_ candidate: LyricsCandidate, _ query: LyricsQuery) -> Int {
        let c = recordingVersions(title: candidate.title, album: candidate.album)
        let q = recordingVersions(title: query.title, album: query.album)
        if c == q { return 0 }
        if c.isEmpty { return -120 }
        return -300
    }

    public static func hasSameRecordingVersion(_ lhs: LyricsCandidate, _ rhs: LyricsCandidate) -> Bool {
        recordingVersions(title: lhs.title, album: lhs.album)
            == recordingVersions(title: rhs.title, album: rhs.album)
    }

    private static func recordingVersions(title: String, album: String?) -> Set<String> {
        let aliases: [(String, [String])] = [
            ("live", ["live", "现场", "演唱会"]),
            ("remix", ["remix", "混音版"]),
            ("demo", ["demo", "小样"]),
            ("acoustic", ["acoustic", "unplugged", "不插电"]),
            ("instrumental", ["instrumental", "inst", "纯音乐"]),
            ("karaoke", ["karaoke", "伴奏"]),
            ("edit", ["edit", "剪辑版"]),
            ("extended", ["extended", "加长版"]),
            ("cover", ["cover", "翻唱"]),
            ("rerecorded", ["re recorded", "rerecorded", "重录"]),
            ("dub", ["dub"]),
        ]
        let titleText = normalizeText(title)
        let albumText = normalizeText(album ?? "")
        let nsTitle = title as NSString
        let bracketed = versionBracketRegex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))
            .map { normalizeText(nsTitle.substring(with: $0.range(at: 1))) }
        var out = Set<String>()
        for (kind, words) in aliases {
            let titleHasVersion = words.contains { word in
                if bracketed.contains(where: { containsVersion(word, in: $0) }) { return true }
                if word.unicodeScalars.contains(where: { $0.value > 127 }) { return titleText.contains(word) }
                if titleText.hasSuffix(" " + word) { return true }
                let padded = " " + titleText + " "
                let suffixCues = ["at", "in", "from", "on", "version", "edit", "mix", "acoustic", "unplugged", "live"]
                return suffixCues.contains { padded.contains(" " + word + " " + $0 + " ") }
            }
            if titleHasVersion { out.insert(kind) }
            let albumHasVersion = words.contains { containsVersion($0, in: albumText) }
            guard albumHasVersion else { continue }
            if kind != "live" || albumText == "live"
                || ["live at", "live in", "live from", "live on", "现场", "演唱会"].contains(where: { albumText.contains($0) })
                || (album ?? "").range(of: #"[\(\[]\s*live\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                out.insert(kind)
            }
        }
        return out
    }

    private static let versionBracketRegex = try! NSRegularExpression(pattern: #"[\(（\[]([^\)）\]]*)[\)）\]]"#)

    private static func containsVersion(_ word: String, in text: String) -> Bool {
        if word.unicodeScalars.contains(where: { $0.value > 127 }) { return text.contains(word) }
        return (" " + text + " ").contains(" " + word + " ")
    }

    private static func titleCore(_ value: String) -> String {
        let tokens = value.split(separator: " ").map(String.init)
        guard let firstTag = tokens.firstIndex(where: { isVersionToken($0) || featWords.contains($0) }) else {
            return value
        }
        var core = Array(tokens[..<firstTag])
        if tokens[firstTag].hasPrefix("remaster"), let last = core.last,
           last.count == 4, let year = Int(last), (1900...2099).contains(year) {
            core.removeLast()
        }
        return core.joined(separator: " ")
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let token = normalizeText(value)
        return versionWords.contains { normalizeText($0) == token }
            || token.hasPrefix("remaster")
            || token.hasPrefix("version")
            || token.hasPrefix("re recorded")
    }

    private static func lyricsSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = lyricShingles(lhs)
        let b = lyricShingles(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func lyricShingles(_ lyrics: String) -> Set<String> {
        let body = ManualPickLock.canonicalLyrics(lyrics).split(separator: "\n")
            .map(String.init).filter(isUsefulText).joined(separator: " ")
        let characters = Array(normalizeText(body))
        guard characters.count >= 3 else { return body.isEmpty ? [] : [normalizeText(body)] }
        return Set((0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) })
    }

    private static func artistParts(_ value: String) -> [String] {
        var value = value
        if let range = value.range(
            of: "\\s+(feat|ft|featuring|with)\\.?\\s+.*$",
            options: [.regularExpression, .caseInsensitive]) {
            value = String(value[..<range.lowerBound])
        }
        return value.split { "/&、,，".contains($0) }
            .map { normalizedArtist(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeText(_ value: String) -> String {
        (value.applyingTransform(.init("Traditional-Simplified"), reverse: false) ?? value)
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[’'`\"“”]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func isUsefulText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreditLine(text)
    }

    private static func isCreditLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("作词") || lower.contains("作曲") || lower.contains("编曲")
            || lower.contains("lyrics by") || lower.contains("written by")
    }
}
