import Foundation

/// Catalog aliases are scoped to an artist; translating a title alone cannot identify a recording.
enum LyricsIdentityAliases {
    // Mintone's catalog lists 飞 / Matt吕彦良; its international release lists Fly / Matt Lv.
    // https://mintone.bandcamp.com/track/--38
    // https://www.youtube.com/watch?v=GtJNvR19RdE
    private static let mattNames: Set<String> = ["吕彦良", "matt吕彦良", "mattlv"]
    private static let flyNames: Set<String> = ["fly", "飞", "飞fly", "fly飞"]

    private static func key(_ value: String) -> String {
        let mutable = NSMutableString(string: value) as CFMutableString
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        return (mutable as String).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                          locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func artist(_ value: String) -> String {
        mattNames.contains(key(value)) ? "Matt吕彦良" : value
    }

    static func title(_ value: String, artist: String) -> String {
        aliasedTitle(value, artist: artist) ?? value
    }

    static func hasTitleAlias(_ value: String, artist: String) -> Bool {
        aliasedTitle(value, artist: artist) != nil
    }

    private static func aliasedTitle(_ value: String, artist: String) -> String? {
        guard mattNames.contains(key(artist)) else { return nil }
        if flyNames.contains(key(value)) { return "飞" }
        // Preserve recording qualifiers verbatim, including Live, remix and language labels.
        if let opening = value.firstIndex(where: { "(（[【".contains($0) }),
           flyNames.contains(key(String(value[..<opening]))) {
            return "飞 " + value[opening...]
        }
        for suffix in ["现场版", "现场", "伴奏版", "伴奏", "混音版"] where value.hasSuffix(suffix) {
            let base = String(value.dropLast(suffix.count))
            if flyNames.contains(key(base)) { return "飞" + suffix }
        }
        return nil
    }

    static func externalQueries(_ query: LyricsQuery) -> [LyricsQuery] {
        let name = artist(query.artist)
        let song = title(query.title, artist: query.artist)
        let preferred = LyricsQuery(title: song, artist: name, album: query.album, duration: query.duration)
        var variants = [preferred, query]
        if hasTitleAlias(query.title, artist: query.artist) {
            variants.append(LyricsQuery(title: "Fly" + song.dropFirst(), artist: "Matt Lv",
                                        album: query.album, duration: query.duration))
        }
        var unique: [LyricsQuery] = []
        for variant in variants where !unique.contains(variant) { unique.append(variant) }
        return unique
    }
}
