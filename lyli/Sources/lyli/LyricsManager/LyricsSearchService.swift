import Foundation
import LyliCore

@MainActor
final class LyricsSearchService: ObservableObject {
    static let shared = LyricsSearchService()

    private let resolver: LyricsResolver
    private let cache: EnrichCacheStore
    enum AutomaticSearchState { case idle, searching, completed, cancelled, failed }
    @Published private(set) var automaticSearchKey: String?
    @Published private(set) var automaticSearchState: AutomaticSearchState = .idle
    private var automaticSearchID: UUID?
    private var automaticCacheRevision = 0
    enum SearchScope: Hashable {
        case manual
        case rematch
        case automatic
    }

    private struct RunningSearch {
        let id: UUID
        let task: Task<LyricsResolution, Never>
    }

    private var runningTasks: [SearchScope: RunningSearch] = [:]

    struct ScoreTerm: Equatable, Decodable {
        let kind: String
        let points: Int

        var label: String {
            switch kind {
            case "duration": return "曲长吻合"
            case "lyricEnd": return "歌词结束位置"
            case "corroborated": return "结束点获印证"
            case "wordTiming": return "逐字时间轴"
            case "nativeSource": return "与当前播放器同源"
            case "lines": return "行数"
            case "versionTags": return "版本不符"
            case "durationOff": return "时长不符"
            case "sourceDurationOff": return "源自报曲长不符"
            case "wordTimingOverride": return "有更吻合的歌名或版本，撤销逐字加分"
            case "liveAlbumConflict": return "是另一场演出的现场版"
            case "durationOvershoot": return "歌词超出曲长"
            case "album": return "专辑吻合"
            case "titleMatch": return "标题吻合"
            case "artistMatch": return "歌手吻合"
            case "consensus": return "内容获印证"
            case "translation": return "自带译文"
            case "rejectNotTimed": return "不是带时间戳的歌词"
            case "rejectWrongArtist": return "歌手跟这首歌对不上"
            case "rejectCreditOnly": return "整份只有署名行，没有正文"
            case "rejectNoLastTimestamp": return "取不到最后一句的时间"
            case "rejectDurationMismatch": return "时长明显对不上，也没有别的源印证"
            case "rejectPlainTextOnly": return "仅有纯文本，没有时间戳"
            case "instrumental": return "纯音乐"
            default: return kind
            }
        }

        var detail: String {
            switch kind {
            case "duration": return "源报告的歌曲时长与当前歌曲接近；歌词后的器乐尾奏不影响这一项"
            case "lyricEnd": return "源未提供曲长时，以最后一句有效歌词的位置作补充参考"
            case "wordTiming": return "带有可解析的逐字（卡拉 OK）时间轴"
            case "lines": return "有效歌词行数，不含空行与署名"
            case "album": return "源返回的专辑与本地资料一致"
            case "titleMatch": return "标题标准化后匹配"
            case "artistMatch": return "歌手标准化后匹配"
            case "consensus": return "歌词正文与其他来源相似，每个来源只计一次；不代表时间轴已经验证"
            case "translation": return "带有可用译文"
            case "versionTags": return "歌名或专辑中的现场、伴奏等录音版本信息不同或缺失；Remaster 不单独扣分"
            case "sourceDurationOff": return "源声明的曲长与本地差异较大"
            case "durationOff": return "歌词结束时间与曲长差异较大"
            case "durationOvershoot": return "歌词结束时间超过歌曲结束"
            case "wordTimingOverride": return "歌名或录音版本更吻合的候选优先"
            case "rejectPlainTextOnly": return "可以作为静态文字阅读，但不能跟随播放高亮"
            default: return ""
            }
        }

        var isRejection: Bool { kind.hasPrefix("reject") }

        static func explanation(score: Int, terms: [ScoreTerm]) -> String {
            guard let first = terms.first else { return "" }
            if first.isRejection {
                let detail = first.detail
                return String(format: "不可用：%@", first.label)
                    + (detail.isEmpty ? "" : "\n" + detail)
            }
            var lines = [String(format: "总分 %@", "\(score)")]
            for term in terms.sorted(by: { abs($0.points) > abs($1.points) }) {
                let signed = "\(term.points > 0 ? "+" : "")\(term.points)"
                let detail = term.detail
                lines.append(detail.isEmpty ? "\(signed)  \(term.label)" : "\(signed)  \(term.label) · \(detail)")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let source: String
        let lyrics: String
        let lyricsTr: String
        let lyricsYRC: String
        let hasWordTiming: Bool
        let score: Int
        let scoreTerms: [ScoreTerm]
        let title: String
        let artist: String
        let album: String
        let isPlainTextOnly: Bool
        let lineCount: Int
        let fingerprint: String
        let consensusPeers: [String]

        var hasTranslation: Bool { !lyricsTr.isEmpty }

        static func countLines(of lyrics: String) -> Int {
            lyrics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    struct Pick: Decodable {
        var winner: String = ""
        var winnerScore: Int = 0
        var scoringVersion: Int = LyricsMatcher.scoringVersion
        var decidable = false
        var sourcesSeen: [String] = []
        var sourcesResponded: [String] = []
        var resolvedDurationSecs: Double = 0
        var mode = "native-swift"
        var decisionJSON = ""

        private enum CodingKeys: String, CodingKey {
            case winner, winnerScore, scoringVersion, decidable, sourcesSeen, sourcesResponded
            case resolvedDurationSecs, mode, decisionJSON
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            winner = try c.decodeIfPresent(String.self, forKey: .winner) ?? ""
            winnerScore = try c.decodeIfPresent(Int.self, forKey: .winnerScore) ?? 0
            scoringVersion = try c.decodeIfPresent(Int.self, forKey: .scoringVersion) ?? LyricsMatcher.scoringVersion
            decidable = try c.decodeIfPresent(Bool.self, forKey: .decidable) ?? false
            sourcesSeen = try c.decodeIfPresent([String].self, forKey: .sourcesSeen) ?? []
            sourcesResponded = try c.decodeIfPresent([String].self, forKey: .sourcesResponded) ?? []
            resolvedDurationSecs = try c.decodeIfPresent(Double.self, forKey: .resolvedDurationSecs) ?? 0
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "native-swift"
            decisionJSON = try c.decodeIfPresent(String.self, forKey: .decisionJSON) ?? ""
        }
    }

    struct SearchUpdate {
        let candidates: [Candidate]
        let networkLooksDown: Bool
        let sourcesDone: Int
        let sourcesTotal: Int
        let round: Int
        let sourceFailureReasonCodes: [String: String]
        let instrumental: Bool
        let pick: Pick?
    }

    enum SearchError: LocalizedError {
        case searchFailed(String)
        var errorDescription: String? {
            switch self { case .searchFailed(let message): return String(format: "搜索失败: %@", message) }
        }
    }

    enum FallbackResult { case plainText, instrumental, none, failed }

    func applyFallback(_ update: SearchUpdate, forKey key: String,
                       hasPlainTextFallback: Bool) async -> FallbackResult {
        guard update.pick?.decidable == true else { return .none }
        if update.instrumental {
            return await cache.setInstrumental(key: key, true) ? .instrumental : .failed
        }
        if !hasPlainTextFallback, let plain = update.candidates.first(where: { $0.isPlainTextOnly }) {
            return await cache.savePlainTextEdit(key: key, plainLyrics: plain.lyrics, source: plain.source)
                ? .plainText : .failed
        }
        return .none
    }

    init(resolver: LyricsResolver = LyricsResolver(), cache: EnrichCacheStore? = nil) {
        self.resolver = resolver
        self.cache = cache ?? .shared
    }

    func stopAutomaticSearch(forKey key: String) async {
        guard key == automaticSearchKey, automaticSearchState == .searching else { return }
        automaticSearchID = nil
        cancelRunning(.automatic)
        automaticSearchState = .cancelled
        if cache.revision(forKey: key) == automaticCacheRevision {
            _ = await cache.recordSearchCancellation(key: key)
        }
    }

    func cancelRunning(_ scope: SearchScope) {
        let search = runningTasks.removeValue(forKey: scope)
        search?.task.cancel()
    }

    func startAutomaticSearch() {
        let source = LocalPlaybackSource.shared
        source.onTrackChanged = { [weak self] artist, title, album, duration in
            guard let self, !title.isEmpty, !artist.isEmpty else { return }
            Task { await self.searchAndSave(artist: artist, title: title, album: album, duration: duration) }
        }
        if !source.title.isEmpty, !source.artist.isEmpty {
            let artist = source.artist
            let title = source.title
            let album = source.album
            let duration = Double(source.currentDurationMs ?? 0) / 1000
            Task { await self.searchAndSave(artist: artist, title: title, album: album, duration: duration) }
        }
    }

    func search(
        artist: String, title: String, album: String, durationSecs: Double = 0,
        pickWinner: Bool = false, currentSource: String = "",
        scope: SearchScope = .manual,
        onUpdate: @escaping @MainActor (SearchUpdate) -> Void
    ) async throws {
        cancelRunning(scope)
        let query = LyricsQuery(title: title, artist: artist, album: album.isEmpty ? nil : album,
                                duration: durationSecs > 0 ? durationSecs : nil)
        let enabledSourceIDs = FeatureSettingsStore.shared.lyricsSourceOrder
            .filter { FeatureSettingsStore.shared.lyricsSources.contains($0) }
            .map(\.rawValue)
        let prioritizeSources = FeatureSettingsStore.shared.lyricsSourceMode == .priority
        let task = Task { [resolver] in
            await resolver.resolve(query, enabledIDs: enabledSourceIDs, prioritizeSources: prioritizeSources)
        }
        let searchID = UUID()
        runningTasks[scope] = RunningSearch(id: searchID, task: task)
        await withTaskCancellationHandler(operation: {
            let resolution = await task.value
            guard !Task.isCancelled, !task.isCancelled else { return }
            if scope == .automatic {
                LocalPlaybackSource.shared.setNetworkDown(resolution.sourcesResponded.isEmpty)
            }
            let candidates = resolution.matches.map(Candidate.init)
            let pick = makePick(resolution: resolution, candidates: candidates, duration: durationSecs)
            let update = SearchUpdate(
                candidates: candidates,
                networkLooksDown: resolution.sourcesResponded.isEmpty,
                sourcesDone: resolution.sourcesSeen.count,
                sourcesTotal: resolution.sourcesSeen.count,
                round: 1,
                sourceFailureReasonCodes: Dictionary(uniqueKeysWithValues: resolution.failures.map { ($0.key, failureCode($0.value)) }),
                instrumental: resolution.instrumental,
                pick: pick)
            onUpdate(update)
        }, onCancel: { task.cancel() })
        if runningTasks[scope]?.id == searchID {
            runningTasks[scope] = nil
        }
    }

    private func makePick(resolution: LyricsResolution, candidates: [Candidate], duration: Double) -> Pick? {
        var pick = Pick()
        pick.sourcesSeen = resolution.sourcesSeen
        pick.sourcesResponded = resolution.sourcesResponded
        pick.resolvedDurationSecs = duration
        pick.decidable = !resolution.sourcesResponded.isEmpty
        guard let winner = resolution.winner, let candidate = candidates.first(where: { $0.source == winner.source && $0.fingerprint == ManualPickLock.fingerprint(lyrics: winner.candidate.lyrics) }) else {
            pick.decisionJSON = decisionJSON(resolution: resolution, candidates: candidates, winner: nil)
            return pick
        }
        pick.winner = candidate.source
        pick.winnerScore = candidate.score
        pick.decidable = true
        pick.decisionJSON = decisionJSON(resolution: resolution, candidates: candidates, winner: candidate)
        return pick
    }

    private func decisionJSON(resolution: LyricsResolution, candidates: [Candidate], winner: Candidate?) -> String {
        let rows = candidates.map { candidate in
            ["source": candidate.source, "score": candidate.score,
             "score_terms": candidate.scoreTerms.map { ["kind": $0.kind, "points": $0.points] },
             "title": candidate.title, "artist": candidate.artist, "album": candidate.album,
             "has_word_timing": candidate.hasWordTiming,
             "consensus_peers": candidate.consensusPeers] as [String: Any]
        }
        let object: [String: Any] = [
            "path": "native-swift", "decided_at": Int(Date().timeIntervalSince1970), "scoring_version": LyricsMatcher.scoringVersion,
            "winner": winner?.source ?? NSNull(), "applied": false, "candidates": rows,
            "sources_responded": resolution.sourcesResponded,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func failureCode(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("timed out") || value.contains("timeout") { return "connect_failed" }
        if value.contains("http 5") { return "server_error" }
        if value.contains("dns") || value.contains("name") { return "dns_failed" }
        return "upstream_unreachable"
    }

    private func decisionObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        object["applied"] = true
        return object
    }

    func searchAndSave(artist: String, title: String, album: String, duration: Double) async {
        cancelRunning(.automatic)
        let searchID = UUID()
        automaticSearchID = searchID
        let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
            ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        automaticSearchKey = key
        let cached = EnrichCacheReader.lookup(artist: artist, title: title, album: album)
        if (cached?.resolved == true && cached?.searchIncomplete != true)
            || cached?.instrumental == true || !(cached?.lyrics.isEmpty ?? true)
            || !(cached?.plainLyrics.isEmpty ?? true) {
            automaticSearchState = .completed
            return
        }
        let revision = cache.revision(forKey: key)
        automaticCacheRevision = revision
        automaticSearchState = .searching
        do {
            var update: SearchUpdate?
            try await search(artist: artist, title: title, album: album, durationSecs: duration,
                             pickWinner: true, scope: .automatic) { value in update = value }
            guard automaticSearchID == searchID, let update, !Task.isCancelled else { return }
            guard cache.revision(forKey: key) == revision,
                  EnrichCacheReader.lookup(artist: artist, title: title, album: album) == cached else {
                automaticSearchState = .completed
                return
            }
            let saved: Bool
            if let winner = update.pick.flatMap({ pick in update.candidates.first { $0.source == pick.winner } }) {
                saved = await cache.saveEdit(
                    key: key, lyrics: winner.lyrics, tr: winner.lyricsTr, yrc: winner.lyricsYRC,
                    source: winner.source, markManual: false,
                    score: winner.score, scoringVersion: LyricsMatcher.scoringVersion, resolvedDurationSecs: duration,
                    sourcesSeen: update.pick?.sourcesSeen ?? [],
                    sourcesResponded: update.pick?.sourcesResponded ?? [],
                    decision: update.pick.flatMap { decisionObject($0.decisionJSON) })
            } else {
                let plain = update.candidates.first { $0.isPlainTextOnly }
                saved = await cache.recordSearchCompletion(
                    key: key, plainLyrics: plain?.lyrics ?? "", plainSource: plain?.source ?? "",
                    instrumental: update.instrumental, duration: duration,
                    sourcesSeen: update.pick?.sourcesSeen ?? [],
                    sourcesResponded: update.pick?.sourcesResponded ?? [],
                    sourcesFailed: update.sourceFailureReasonCodes.keys.sorted(),
                    decision: update.pick.flatMap { decisionObject($0.decisionJSON) })
            }
            guard automaticSearchID == searchID else { return }
            automaticSearchState = saved && !update.networkLooksDown ? .completed : .failed
        } catch {
            if automaticSearchID == searchID { automaticSearchState = .failed }
        }
    }
}

private extension LyricsSearchService.Candidate {
    init(_ match: LyricsMatch) {
        self.init(source: match.source, lyrics: match.candidate.lyrics,
                  lyricsTr: match.candidate.translation ?? "",
                  lyricsYRC: match.candidate.wordTiming ?? "", hasWordTiming: match.candidate.hasWordTiming,
                  score: match.score, scoreTerms: match.terms.map { .init(kind: $0.kind, points: $0.points) },
                  title: match.candidate.title, artist: match.candidate.artist,
                  album: match.candidate.album ?? "",
                  isPlainTextOnly: match.candidate.plainTextOnly,
                  lineCount: Self.countLines(of: match.candidate.lyrics),
                  fingerprint: ManualPickLock.fingerprint(lyrics: match.candidate.lyrics),
                  consensusPeers: match.consensusPeers)
    }
}
