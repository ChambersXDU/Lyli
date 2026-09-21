import Foundation

public struct EnrichCacheLyrics: Equatable {
    public let lyrics: String
    public let lyricsTr: String
    public let lyricsRoma: String
    public let lyricsYRC: String
    public let instrumental: Bool
    public let resolved: Bool
    public let plainLyrics: String
    public let searchIncomplete: Bool
}

@MainActor
public enum EnrichCacheReader {
    private static let cacheURL = LyliPaths.configFile("lyli-enrich-cache.json")

    private static var cacheEntries: [String: [String: Any]]?
    private static var looseKeyIndex: [String: String]?
    private static var artistTitleKeyIndex: [String: String]?
    private static var cacheContentVersion: Date?

    public struct SourceInfo: Sendable, Equatable {
        public let lyricsSource: String?
    }

    public static var entries: [String: [String: Any]] {
        get { loadedEntries() }
        set {
            cacheEntries = newValue
            invalidateIndexes()
        }
    }

    public static var contentVersion: Date? {
        _ = loadedEntries()
        return cacheContentVersion
    }

    public static func sourceInfo(artist: String, title: String, album: String) -> SourceInfo? {
        guard let entry = matchedEntry(artist: artist, title: title, album: album) else { return nil }
        return SourceInfo(
            lyricsSource: entry["lyrics_source"] as? String)
    }

    public static func resolvedKey(artist: String, title: String, album: String) -> String? {
        matchingKey(artist: artist, title: title, album: album)
    }

    public static func lookup(artist: String, title: String, album: String) -> EnrichCacheLyrics? {
        guard let entry = matchedEntry(artist: artist, title: title, album: album) else { return nil }
        let lyrics = entry["lyrics"] as? String ?? ""
        let sourcesSkipped = entry["lyrics_sources_skipped"] as? [String] ?? []
        let sourcesFailed = entry["lyrics_sources_failed"] as? [String] ?? []
        return EnrichCacheLyrics(
            lyrics: lyrics,
            lyricsTr: entry["lyrics_tr"] as? String ?? "",
            lyricsRoma: entry["lyrics_roma"] as? String ?? "",
            lyricsYRC: entry["lyrics_yrc"] as? String ?? "",
            instrumental: entry["instrumental"] as? Bool ?? false,
            resolved: (number(entry["ts"]) ?? 0) > 0,
            plainLyrics: entry["plain_lyrics"] as? String ?? "",
            searchIncomplete: lyrics.isEmpty
                && (!sourcesSkipped.isEmpty || !sourcesFailed.isEmpty)
                && (number(entry["lyrics_fill_count"]) ?? 0) == 0)
    }

    public static func reloadNow() -> Bool {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            cacheEntries = [:]
            cacheContentVersion = nil
            invalidateIndexes()
            return false
        }
        cacheEntries = decoded
        cacheContentVersion = Date()
        invalidateIndexes()
        return true
    }

    public static func noteCacheWrite() {
        cacheContentVersion = Date()
        invalidateIndexes()
    }

    private static func loadedEntries() -> [String: [String: Any]] {
        if cacheEntries == nil { _ = reloadNow() }
        return cacheEntries ?? [:]
    }

    private static func matchedEntry(artist: String, title: String, album: String) -> [String: Any]? {
        guard let key = matchingKey(artist: artist, title: title, album: album) else { return nil }
        return loadedEntries()[key]
    }

    private static func matchingKey(
        artist: String, title: String, album: String, includeArtistTitle: Bool = true
    ) -> String? {
        let all = loadedEntries()
        let key = EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        if all[key] != nil { return key }
        if let loose = looseIndex(in: all)[EnrichCacheKeys.looseKey(key)] { return loose }
        guard includeArtistTitle else { return nil }
        return artistTitleIndex(in: all)[artistTitleKey(artist: artist, title: title)]
    }

    private static func looseIndex(in all: [String: [String: Any]]) -> [String: String] {
        if let looseKeyIndex { return looseKeyIndex }
        var index: [String: String] = [:]
        index.reserveCapacity(all.count)
        for key in all.keys {
            let loose = EnrichCacheKeys.looseKey(key)
            if let existing = index[loose] {
                if key < existing { index[loose] = key }
            } else {
                index[loose] = key
            }
        }
        looseKeyIndex = index
        return index
    }

    private static func artistTitleIndex(in all: [String: [String: Any]]) -> [String: String] {
        if let artistTitleKeyIndex { return artistTitleKeyIndex }
        var index: [String: String] = [:]
        var aliases: [String: String] = [:]
        for key in all.keys.sorted() {
            guard let parts = splitKey(key), let entry = all[key] else { continue }
            let exact = artistTitleKey(artist: parts.artist, title: parts.title)
            select(&index, normalized: exact, key: key, entry: entry, all: all)
            let alias = artistTitleKey(artist: ArtistCredit.mergeArtist(parts.artist), title: parts.title)
            if alias != exact { select(&aliases, normalized: alias, key: key, entry: entry, all: all) }
        }
        for (key, value) in aliases where index[key] == nil { index[key] = value }
        artistTitleKeyIndex = index
        return index
    }

    private static func select(
        _ index: inout [String: String], normalized: String, key: String,
        entry: [String: Any], all: [String: [String: Any]]
    ) {
        guard let existing = index[normalized] else {
            index[normalized] = key
            return
        }
        if entryRank(entry) > entryRank(all[existing] ?? [:]) { index[normalized] = key }
    }

    private static func splitKey(_ key: String) -> (artist: String, title: String, album: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    private static func artistTitleKey(artist: String, title: String) -> String {
        artist.trimmingCharacters(in: .whitespaces).lowercased()
            + "|" + EnrichCacheKeys.normalizedTitle(title).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func entryRank(_ entry: [String: Any]) -> Int {
        if !(entry["lyrics"] as? String ?? "").isEmpty || !(entry["lyrics_yrc"] as? String ?? "").isEmpty { return 3 }
        if !(entry["plain_lyrics"] as? String ?? "").isEmpty || (entry["instrumental"] as? Bool ?? false) { return 2 }
        return (number(entry["ts"]) ?? 0) > 0 ? 1 : 0
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func invalidateIndexes() {
        looseKeyIndex = nil
        artistTitleKeyIndex = nil
    }
}
