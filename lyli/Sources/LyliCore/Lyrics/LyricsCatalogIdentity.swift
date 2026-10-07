import Foundation

/// Broadens retrieval only when album and duration can constrain the recording.
enum LyricsCatalogIdentity {
    static func fallbackQuery(_ query: LyricsQuery) -> LyricsQuery? {
        guard let album = query.album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let duration = query.duration, duration.isFinite, duration > 0,
              !query.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LyricsQuery(title: query.title, artist: query.artist, album: album,
                           duration: duration, catalogFallback: true)
    }

    static func searchText(_ query: LyricsQuery) -> String {
        query.catalogFallback ? "\(query.artist) \(query.album ?? "")" : "\(query.artist) \(query.title)"
    }

    static func matches(title: String, artist: String, album: String?, duration: Double?, query: LyricsQuery) -> Bool {
        guard let a = album, let b = query.album,
              !LyricsMatcher.normalizedTitle(a).isEmpty,
              LyricsMatcher.normalizedTitle(a) == LyricsMatcher.normalizedTitle(b),
              let actual = duration, let expected = query.duration,
              actual.isFinite, expected.isFinite, actual > 0, expected > 0,
              abs(actual - expected) <= 2,
              LyricsMatcher.normalizedArtist(artist) == LyricsMatcher.normalizedArtist(query.artist),
              !LyricsMatcher.normalizedArtist(artist).isEmpty else { return false }
        let candidate = LyricsCandidate(source: "catalog", lyrics: "", title: title, album: album)
        let reference = LyricsCandidate(source: "catalog", lyrics: "", title: query.title, album: query.album)
        return LyricsMatcher.hasSameRecordingVersion(candidate, reference)
    }
}
