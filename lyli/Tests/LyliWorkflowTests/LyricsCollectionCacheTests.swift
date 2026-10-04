@testable import lyli

@MainActor
struct LyricsCollectionCacheTests {
    func testRepeatedReadsReuseSortedResults() {
        let cache = LyricsCollectionCache<Int>()
        let key = LyricsCollectionCacheKey(filterToken: "all", summariesGeneration: 1,
                                          pinsGeneration: 0, sortToken: "ascending")
        let input = Array((0..<10_000).reversed())
        var sorts = 0
        for _ in 0..<100 {
            let result = cache.result(for: key) {
                sorts += 1
                return input.sorted()
            }
            expectEqual(result.first, 0)
            expectEqual(result.last, 9_999)
        }
        expectEqual(sorts, 1)
    }

    func testAllCollectionInputsInvalidateResults() {
        let cache = LyricsCollectionCache<String>()
        let keys = [
            LyricsCollectionCacheKey(filterToken: "all", summariesGeneration: 1, pinsGeneration: 0),
            LyricsCollectionCacheKey(filterToken: "manual", summariesGeneration: 1, pinsGeneration: 0),
            LyricsCollectionCacheKey(filterToken: "manual", summariesGeneration: 2, pinsGeneration: 0),
            LyricsCollectionCacheKey(filterToken: "manual", summariesGeneration: 2, pinsGeneration: 1),
            LyricsCollectionCacheKey(filterToken: "manual", summariesGeneration: 2, pinsGeneration: 1,
                                     sortToken: "descending"),
        ]
        var builds = 0
        for (index, key) in keys.enumerated() {
            for _ in 0..<2 {
                let result = cache.result(for: key) {
                    builds += 1
                    return ["result-\(index)"]
                }
                expectEqual(result, ["result-\(index)"])
            }
        }
        expectEqual(builds, keys.count)
    }

    func testEmptyResultsAndReturningToPreviousFilter() {
        let cache = LyricsCollectionCache<String>()
        let all = LyricsCollectionCacheKey(filterToken: "all", summariesGeneration: 0, pinsGeneration: 0)
        let missing = LyricsCollectionCacheKey(filterToken: "missing", summariesGeneration: 0,
                                              pinsGeneration: 0)
        expectEqual(cache.result(for: all) { ["song"] }, ["song"])
        expectEqual(cache.result(for: missing) { [] }, [])
        expectEqual(cache.result(for: missing) { ["stale"] }, [])
        expectEqual(cache.result(for: all) { ["updated song"] }, ["updated song"])
    }
}
