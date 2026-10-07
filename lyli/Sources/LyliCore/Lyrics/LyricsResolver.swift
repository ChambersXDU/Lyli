import Foundation

public struct LyricsResolver: Sendable {
    private let providers: [any LyricsProvider]

    public init(providers: [any LyricsProvider] = LyricsResolver.defaultProviders()) {
        self.providers = providers
    }

    public static func defaultProviders() -> [any LyricsProvider] {
        [AppleMusicCacheProvider(), LRCLIBProvider(), KuwoProvider(), NeteaseProvider(), KugouProvider(), QQMusicProvider()]
    }

    public func resolve(_ query: LyricsQuery, enabledIDs: [String]? = nil,
                        prioritizeSources: Bool = false, localOnly: Bool = false, preferLocal: Bool = false) async -> LyricsResolution {
        struct Result: Sendable {
            let id: String
            let candidates: [LyricsCandidate]
            let error: String?
        }

        let enabledProviders = enabledIDs.map { ids in
            providers.filter { ids.contains($0.id) }
        } ?? providers
        let providersToUse = localOnly ? enabledProviders.filter { $0.id == "appleMusic" } : enabledProviders
        if preferLocal, !localOnly, providersToUse.contains(where: { $0.id == "appleMusic" }) {
            let local = await resolve(query, enabledIDs: enabledIDs, localOnly: true)
            if local.winner != nil { return local }
        }

        let results = await withTaskGroup(of: Result.self, returning: [Result].self) { group in
            for provider in providersToUse {
                group.addTask {
                    let queries = provider.id == "appleMusic" ? [query] : LyricsIdentityAliases.externalQueries(query)
                    var candidates: [LyricsCandidate] = []
                    var responded = false
                    var lastError: String?
                    for variant in queries {
                        guard !Task.isCancelled else { break }
                        do {
                            candidates.append(contentsOf: try await provider.search(variant))
                            responded = true
                            if LyricsMatcher.rank(candidates, for: query).contains(where: {
                                !$0.isRejected && !$0.candidate.instrumental
                                    && $0.terms.contains { $0.kind == "titleMatch" && $0.points > 0 }
                                    && !$0.terms.contains { $0.kind == "versionTags" && $0.points < 0 }
                            }) { break }
                        } catch { lastError = error.localizedDescription }
                    }
                    return Result(id: provider.id, candidates: candidates, error: responded ? nil : lastError)
                }
            }
            var values: [Result] = []
            for await result in group {
                values.append(result)
            }
            return values
        }

        let sourcesSeen = providersToUse.map(\.id)
        let sourcesResponded = results.filter { $0.error == nil }.map(\.id).sorted()
        let failures = Dictionary(uniqueKeysWithValues: results.compactMap { result in
            result.error.map { (result.id, $0) }
        })
        let candidates = results.flatMap(\.candidates)
        let matches = LyricsMatcher.rank(candidates, for: query,
                                         sourceOrder: enabledIDs ?? [], prioritizeSources: prioritizeSources)
        let instrumental = candidates.contains { $0.instrumental }
        return LyricsResolution(matches: matches, sourcesSeen: sourcesSeen,
                                sourcesResponded: sourcesResponded, failures: failures,
                                instrumental: instrumental)
    }

}
