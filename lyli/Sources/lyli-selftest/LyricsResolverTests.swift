import Foundation
import LyliCore

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    var current: Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum StubProviderError: Error, Sendable {
    case unavailable
}

private struct StubProvider: LyricsProvider {
    let id: String
    let candidates: [LyricsCandidate]
    let fails: Bool
    let delayNanoseconds: UInt64
    let calls: LockedInt?

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        calls?.increment()
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if fails { throw StubProviderError.unavailable }
        return candidates
    }
}

private struct CatalogProbeProvider: LyricsProvider {
    let id: String
    let calls: LockedBox<[LyricsQuery]>
    let result: LyricsCandidate
    var firstFails = false

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        calls.set((calls.current ?? []) + [query])
        if firstFails && calls.current?.count == 1 { throw StubProviderError.unavailable }
        return query.catalogFallback ? [result] : []
    }
}

private func candidate(
    source: String,
    title: String,
    artist: String,
    album: String? = nil,
    end: Int = 180,
    lyrics: [String] = ["one", "two"]
) -> LyricsCandidate {
    let timedLines = lyrics.enumerated().map { index, text in
        String(format: "[00:%02d.00]%@", index + 1, text)
    }
    let last = String(format: "[%02d:%02d.00]last", end / 60, end % 60)
    return LyricsCandidate(
        source: source,
        lyrics: (timedLines + [last]).joined(separator: "\n"),
        duration: Double(end),
        title: title,
        artist: artist,
        album: album
    )
}

private func resolveSynchronously(
    _ resolver: LyricsResolver,
    query: LyricsQuery,
    enabledIDs: [String]? = nil
) -> LyricsResolution? {
    let result = LockedBox<LyricsResolution>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        result.set(await resolver.resolve(query, enabledIDs: enabledIDs))
        semaphore.signal()
    }
    semaphore.wait()
    return result.current
}

func runLyricsResolverTests() {
    let translatedQuery = LyricsQuery(title: "Clouds", artist: "林小雨", album: "First Light", duration: 180)
    let body = ["天空的云慢慢走过山丘我们抬起头", "风吹过河流带来很久以前的问候", "你的笑容留在每个清晨温暖心中", "把故事写进月光带着梦一起远行"]
    let translated = candidate(source: "qq", title: "云朵", artist: "Lynn林小雨", album: "First Light", lyrics: body)
    let peer = candidate(source: "netease", title: "云朵", artist: "林小雨", album: "First Light", lyrics: body)
    let calls = LockedBox<[LyricsQuery]>()
    let peerCalls = LockedBox<[LyricsQuery]>()
    let result = resolveSynchronously(LyricsResolver(providers: [
        CatalogProbeProvider(id: "qq", calls: calls, result: translated),
        CatalogProbeProvider(id: "netease", calls: peerCalls, result: peer)
    ]), query: translatedQuery)
    expectEqual(result?.winner?.isRejected, false, "无歌曲字典也能验证翻译歌名")
    expectEqual(calls.current?.map(\.catalogFallback), [false, true], "正常检索失败后仅一次受约束的专辑检索")
    expectEqual(calls.current?.last?.title, "Clouds", "扩大检索不伪造翻译歌名")
    expectEqual(calls.current?.last?.artist, "林小雨")
    expectEqual(calls.current?.last?.album, "First Light")
    let failedCalls = LockedBox<[LyricsQuery]>()
    let recovered = resolveSynchronously(LyricsResolver(providers: [
        CatalogProbeProvider(id: "qq", calls: failedCalls, result: translated, firstFails: true),
        CatalogProbeProvider(id: "netease", calls: LockedBox(), result: peer)
    ]), query: translatedQuery)
    expectEqual(recovered?.failures.isEmpty, true, "原查询失败后目录检索成功不误报来源离线")
    let noEvidence = resolveSynchronously(LyricsResolver(providers: [
        CatalogProbeProvider(id: "qq", calls: LockedBox(), result: translated)
    ]), query: translatedQuery)
    expectEqual(noEvidence?.winner == nil, true, "孤立翻译歌名不能仅靠专辑曲长自动采用")
    let reference = candidate(source: "appleMusic", title: "Clouds", artist: "林小雨", album: "First Light", lyrics: body)
    let anchored = LockedBox<LyricsResolution>()
    let anchorWait = DispatchSemaphore(value: 0)
    Task.detached {
        anchored.set(await LyricsResolver(providers: [CatalogProbeProvider(id: "qq", calls: LockedBox(), result: translated)])
            .resolve(translatedQuery, reference: reference))
        anchorWait.signal()
    }
    anchorWait.wait()
    expectEqual(anchored.current?.winner?.candidate, translated, "已识别官方正文可验证单个外部译名")
    expectEqual(anchored.current?.matches.count, 1, "官方参考不伪装成本轮检索结果")
    let incompleteCalls = LockedBox<[LyricsQuery]>()
    _ = resolveSynchronously(LyricsResolver(providers: [CatalogProbeProvider(id: "qq", calls: incompleteCalls, result: translated)]),
        query: LyricsQuery(title: "Clouds", artist: "林小雨", duration: 180))
    expectEqual(incompleteCalls.current?.count, 1, "资料不足不扩大检索")
    let localCalls = LockedBox<[LyricsQuery]>()
    _ = resolveSynchronously(LyricsResolver(providers: [CatalogProbeProvider(id: "appleMusic", calls: localCalls, result: translated)]),
        query: translatedQuery)
    expectEqual(localCalls.current, [translatedQuery], "本地官方缓存不扩大检索")

    let query = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
    let exact = candidate(source: "exact", title: "Song", artist: "Artist", album: "Album")
    let wrongArtist = candidate(source: "wrong-artist", title: "Song", artist: "Someone Else", end: 180)
    let live = candidate(source: "live", title: "Song (Live)", artist: "Artist", end: 178)
    let far = candidate(source: "far", title: "Song", artist: "Artist", end: 360)
    let wrongTitle = candidate(source: "wrong-title", title: "Other Song", artist: "Artist")

    let ranked = LyricsMatcher.rank([wrongArtist, live, far, exact], for: query)
    expectEqual(ranked.first?.source, "exact", "正确候选排第一")
    expectEqual(ranked.first?.isRejected, false)
    expectEqual(ranked.last?.source, "wrong-artist", "明显错误歌手被放到拒绝结果")
    expectEqual(ranked.last?.isRejected, true)

    let versions = LyricsMatcher.rank([live, exact], for: query)
    expectEqual(versions.map(\.source), ["exact", "live"], "原版压过 Live 版本")
    expectEqual(versions.last?.isRejected, false)

    let durations = LyricsMatcher.rank([far, exact], for: query)
    expectEqual(durations.map(\.source), ["exact", "far"], "时长明显不符的候选被压低")
    expectEqual(durations.last?.isRejected, false)

    let outro = candidate(source: "outro", title: "Song", artist: "Artist", album: "Album", end: 110)
    let outroMatch = LyricsMatcher.rank([outro], for: query).first
    expectEqual(outroMatch?.terms.contains { $0.kind == "durationOff" }, false,
                "器乐尾奏不构成时长冲突")

    let priority = LyricsMatcher.rank([exact, outro], for: query,
                                      sourceOrder: ["outro", "exact"], prioritizeSources: true)
    expectEqual(priority.first?.source, "outro", "顺序优先使用用户配置的来源顺序")

    let titles = LyricsMatcher.rank([wrongTitle, exact], for: query)
    expectEqual(titles.first?.source, "exact", "明显错误 title 不抢占正确结果")
    expectEqual(titles.last?.isRejected, false)

    let disabledCalls = LockedInt()
    let disabled = resolveSynchronously(
        LyricsResolver(providers: [StubProvider(
            id: "disabled",
            candidates: [exact],
            fails: false,
            delayNanoseconds: 0,
            calls: disabledCalls,
        )]),
        query: query,
        enabledIDs: []
    )
    expectEqual(disabled?.sourcesSeen ?? [], [], "零个启用 Provider 不发请求")
    expectEqual(disabled?.sourcesResponded ?? [], [])
    expectEqual(disabledCalls.current, 0)

    let networkCalls = LockedInt()
    let localCandidate = candidate(source: "appleMusic", title: "Song", artist: "Artist", album: "Album")
    let localResolver = LyricsResolver(providers: [
        StubProvider(id: "appleMusic", candidates: [localCandidate], fails: false, delayNanoseconds: 0, calls: nil),
        StubProvider(id: "network", candidates: [exact], fails: false, delayNanoseconds: 0, calls: networkCalls)
    ])
    let localResult = LockedBox<LyricsResolution>()
    let localWait = DispatchSemaphore(value: 0)
    Task.detached {
        localResult.set(await localResolver.resolve(query, preferLocal: true))
        localWait.signal()
    }
    localWait.wait()
    expectEqual(localResult.current?.winner?.source, "appleMusic", "官方本地歌词优先")
    expectEqual(networkCalls.current, 0, "本地命中不发送网络请求")
    let fallback = resolveSynchronously(LyricsResolver(providers: [
        StubProvider(id: "appleMusic", candidates: [], fails: true, delayNanoseconds: 0, calls: nil),
        StubProvider(id: "network", candidates: [exact], fails: false, delayNanoseconds: 0, calls: networkCalls)
    ]), query: query)
    expectEqual(fallback?.winner?.source, "exact", "本地缓存不可读不影响其他来源")
    expectEqual(networkCalls.current, 1)

    let concurrent = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(
                id: "one",
                candidates: [candidate(source: "one", title: "Song (Live)", artist: "Artist", end: 178)],
                fails: false,
                delayNanoseconds: 40_000_000,
                calls: nil
            ),
            StubProvider(
                id: "two",
                candidates: [candidate(source: "two", title: "Song (Remastered)", artist: "Artist", end: 179)],
                fails: false,
                delayNanoseconds: 10_000_000,
                calls: nil
            ),
        ]),
        query: query
    )
    expectEqual(concurrent?.sourcesSeen ?? [], ["one", "two"], "多个 Provider 都被纳入搜索")
    expectEqual(concurrent?.sourcesResponded ?? [], ["one", "two"], "多个 Provider 可以并发返回")
    expectEqual(concurrent?.matches.count, 2)

    let healthy = candidate(source: "healthy", title: "Song (Live)", artist: "Artist", end: 178)
    let isolatedFailure = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(id: "healthy", candidates: [healthy], fails: false, delayNanoseconds: 10_000_000, calls: nil),
            StubProvider(id: "broken", candidates: [], fails: true, delayNanoseconds: 10_000_000, calls: nil),
        ]),
        query: query
    )
    expectEqual(isolatedFailure?.sourcesResponded ?? [], ["healthy"], "一个 Provider 失败不拖垮其他结果")
    expectEqual(isolatedFailure?.failures.keys.sorted() ?? [], ["broken"])
    expectEqual(isolatedFailure?.winner?.source, "healthy")
    expectEqual(isolatedFailure?.matches.first?.source, "healthy")

    let firstCalls = LockedInt()
    let secondCalls = LockedInt()
    let filtered = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(id: "first", candidates: [healthy], fails: false, delayNanoseconds: 0, calls: firstCalls),
            StubProvider(id: "second", candidates: [healthy], fails: false, delayNanoseconds: 0, calls: secondCalls),
        ]),
        query: query,
        enabledIDs: ["first"]
    )
    expectEqual(filtered?.sourcesSeen ?? [], ["first"])
    expectEqual(filtered?.sourcesResponded ?? [], ["first"])
    expectEqual(firstCalls.current, 2, "只有版本冲突候选时尝试一次目录回退")
    expectEqual(secondCalls.current, 0)

    let earlyQuery = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
    let started = Date()
    let early = resolveSynchronously(
        LyricsResolver(providers: [
            StubProvider(
                id: "fast",
                candidates: [candidate(source: "fast", title: "Song", artist: "Artist", album: "Album")],
                fails: false,
                delayNanoseconds: 0,
                calls: nil
            ),
            StubProvider(id: "slow", candidates: [], fails: false, delayNanoseconds: 1_000_000_000, calls: nil),
        ]),
        query: earlyQuery
    )
    expectEqual(early?.winner?.source, "fast", "高置信候选可以提前结束")
    expectEqual(early?.sourcesResponded ?? [], ["fast", "slow"], "普通 LRC 不应截断仍在搜索的逐字源")
    expectEqual(Date().timeIntervalSince(started) >= 0.5, true)
}
