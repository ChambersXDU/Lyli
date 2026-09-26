import Foundation
import LyliCore

func runCacheLookupTests() {
    MainActor.assumeIsolated {
        let original = EnrichCacheReader.entries
        defer { EnrichCacheReader.entries = original }

        EnrichCacheReader.entries = [
            "Artist|Song|Studio": ["lyrics": "studio lyrics"]
        ]
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Studio")?.lyrics,
                    "studio lyrics", "exact album uses its cached lyrics")
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Live")?.lyrics,
                    nil, "different album does not reuse lyrics")

        EnrichCacheReader.entries["Artist|Song|"] = ["lyrics": "albumless lyrics"]
        expectEqual(EnrichCacheReader.lookup(artist: "Artist", title: "Song", album: "Live")?.lyrics,
                    "albumless lyrics", "albumless cache can serve as a fallback")
    }
}
