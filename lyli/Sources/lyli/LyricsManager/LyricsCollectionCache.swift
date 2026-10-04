struct LyricsCollectionCacheKey: Equatable {
    let filterToken: String
    let summariesGeneration: Int
    let pinsGeneration: Int
    var sortToken: String = ""
}

final class LyricsCollectionCache<Element> {
    private var key: LyricsCollectionCacheKey?
    private var items: [Element] = []

    func result(for key: LyricsCollectionCacheKey, build: () -> [Element]) -> [Element] {
        if self.key != key {
            items = build()
            self.key = key
        }
        return items
    }
}
