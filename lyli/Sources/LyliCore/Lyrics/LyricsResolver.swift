import Foundation

public struct LyricsResolver: Sendable {
    private let providers: [any LyricsProvider]

    public init(providers: [any LyricsProvider] = LyricsResolver.defaultProviders()) {
        self.providers = providers
    }

    public static func defaultProviders() -> [any LyricsProvider] {
        [LRCLIBProvider(), KuwoProvider(), NeteaseProvider(), KugouProvider(), QQMusicProvider()]
    }

    public func resolve(_ query: LyricsQuery, enabledIDs: [String]? = nil,
                        prioritizeSources: Bool = false) async -> LyricsResolution {
        struct Result: Sendable {
            let id: String
            let candidates: [LyricsCandidate]
            let error: String?
        }

        let providersToUse = enabledIDs.map { ids in
            providers.filter { ids.contains($0.id) }
        } ?? providers

        let results = await withTaskGroup(of: Result.self, returning: [Result].self) { group in
            for provider in providersToUse {
                group.addTask {
                    do {
                        return Result(id: provider.id, candidates: try await provider.search(query), error: nil)
                    } catch {
                        return Result(id: provider.id, candidates: [], error: error.localizedDescription)
                    }
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
