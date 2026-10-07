import Foundation
import CSQLite

/// Reads response bodies only. Request headers, cookies and signed requests are never accessed.
public struct AppleMusicCacheProvider: LyricsProvider {
    public let id = "appleMusic"
    public let cacheDirectory: URL
    private let preferredLanguages: [String]
    public typealias MetadataLookup = @Sendable ([String]) async throws -> [AppleMusicCatalogSong]
    private let metadataLookup: MetadataLookup
    private static let maximumBodyBytes = 8_000_000

    public init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/com.apple.Music"),
                preferredLanguages: [String] = Locale.preferredLanguages,
                metadataLookup: MetadataLookup? = nil) {
        self.cacheDirectory = cacheDirectory
        self.preferredLanguages = preferredLanguages
        self.metadataLookup = metadataLookup ?? { await AppleMusicCatalogLookup.shared.lookup($0) }
    }

    public enum CacheError: LocalizedError {
        case unavailable
        public var errorDescription: String? { "Apple Music 本地缓存暂不可读" }
    }

    public func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        guard !query.title.isEmpty, !query.artist.isEmpty else { return [] }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try self.snapshot() }
        let cached = try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: { worker.cancel() })
        let local = candidates(cached, query: query)
        guard local.isEmpty else { return local }
        var seen = Set<String>()
        let ids = cached.lyrics.map(\.id).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return [] }
        let metadata = (try? await metadataLookup(ids)) ?? []
        try Task.checkCancellation()
        return candidates(cached, query: query, supplemental: metadata)
    }

    public func read(_ query: LyricsQuery) throws -> [LyricsCandidate] {
        guard !query.title.isEmpty, !query.artist.isEmpty else { return [] }
        return candidates(try snapshot(), query: query)
    }

    private struct Snapshot: Sendable {
        var songs: [String: Song] = [:]
        var lyrics: [(id: String, xml: String)] = []
    }

    private func snapshot() throws -> Snapshot {
        let database = cacheDirectory.appendingPathComponent("Cache.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return Snapshot() }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw CacheError.unavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        // A short read transaction keeps the lyric/catalog association coherent while Music writes.
        guard sqlite3_exec(connection, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw CacheError.unavailable }
        defer { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
        let lyricRows = try rows(connection, filter: "r.request_key LIKE '%ttmlLyrics%' OR r.request_key LIKE '%syllable-lyrics%'", limit: 160)
        guard !lyricRows.isEmpty else { return Snapshot() }
        let catalogRows = try rows(connection, filter: "r.request_key LIKE 'https://amp-api%.music.apple.com/%' OR r.request_key LIKE 'https://client-api.itunes.apple.com/%/lookup%'", limit: 512)
        var songs: [String: Song] = [:]
        var embedded: [(Song, String)] = []
        for row in catalogRows + lyricRows {
            guard let data = body(row), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectSongs(object, into: &songs, embedded: &embedded)
        }
        var snapshot = Snapshot(songs: songs, lyrics: embedded.map { ($0.0.id, $0.1) })
        for row in lyricRows {
            guard let url = URLComponents(string: row.key),
                  url.path.hasSuffix("/ttmlLyrics"),
                  let songID = url.queryItems?.first(where: { $0.name == "id" })?.value,
                  let data = body(row),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["status"] as? String == "success", let ttml = object["ttml"] as? String else { continue }
            snapshot.lyrics.append((songID, ttml))
        }
        return snapshot
    }

    private func candidates(_ snapshot: Snapshot, query: LyricsQuery,
                            supplemental: [Song] = []) -> [LyricsCandidate] {
        let extra = Dictionary(grouping: supplemental, by: \.id)
        var seen = Set<String>()
        return snapshot.lyrics.compactMap { songID, xml in
            let options = snapshot.songs[songID].map { [$0] } ?? []
            guard let song = (options + (extra[songID] ?? [])).first(where: { matchesQuery($0, query) }),
                  !seen.contains(song.id),
                  let parsed = AppleMusicTTMLParser.parse(xml, preferredLanguages: preferredLanguages),
                  LyricsMatcher.isValidTimedLyrics(parsed.lyrics) else { return nil }
            // Album identity or a close catalog duration is required; title alone is insufficient.
            let duration = song.duration ?? query.duration
            if let duration, Double(parsed.endMs) / 1000 > duration + 5 { return nil }
            seen.insert(song.id)
            return LyricsCandidate(source: id, lyrics: parsed.lyrics, translation: parsed.translation,
                                   wordTiming: parsed.wordTiming, duration: duration,
                                   title: song.title, artist: query.artist, album: song.album)
        }
    }

    private struct Row { let key: String; let onDisk: Bool; let data: Data }
    private typealias Song = AppleMusicCatalogSong

    private func rows(_ db: OpaquePointer?, filter: String, limit: Int) throws -> [Row] {
        let sql = """
        SELECT r.request_key,d.isDataOnFS,d.receiver_data
        FROM cfurl_cache_response r JOIN cfurl_cache_receiver_data d USING(entry_ID)
        WHERE (\(filter)) AND length(d.receiver_data) <= \(Self.maximumBodyBytes)
        ORDER BY r.time_stamp DESC,r.entry_ID DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CacheError.unavailable }
        defer { sqlite3_finalize(statement) }
        var values: [Row] = []
        var totalBytes = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw CacheError.unavailable }
            guard let key = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 2))
            guard totalBytes + count <= 32_000_000 else { continue }
            totalBytes += count
            values.append(Row(key: String(cString: key), onDisk: sqlite3_column_int(statement, 1) != 0,
                              data: Data(bytes: bytes, count: count)))
        }
    }

    private func body(_ row: Row) -> Data? {
        guard row.onDisk else { return row.data }
        guard let filename = String(data: row.data, encoding: .utf8), UUID(uuidString: filename) != nil else { return nil }
        let directory = cacheDirectory.appendingPathComponent("fsCachedData").resolvingSymlinksInPath()
        let file = directory.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == directory,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumBodyBytes else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    private func matchesQuery(_ song: Song, _ query: LyricsQuery) -> Bool {
        guard comparable(song.title) == comparable(query.title),
              comparable(song.artist) == comparable(query.artist) else { return false }
        let albumMatches = query.album.flatMap { album in
            song.album.map { comparable($0) == comparable(album) && !album.isEmpty }
        } ?? false
        if let expected = query.duration, let duration = song.duration {
            guard expected.isFinite, expected > 0, abs(expected - duration) <= 3 else { return false }
            return query.album?.isEmpty != false || song.album?.isEmpty != false || albumMatches
        }
        return albumMatches
    }

    private func comparable(_ text: String) -> String {
        LyricsMatcher.normalizedTitle(text)
    }

    private func collectSongs(_ object: Any, into songs: inout [String: Song], embedded: inout [(Song, String)], depth: Int = 0) {
        guard depth < 24 else { return }
        if let dict = object as? [String: Any] {
            let attributes = dict["attributes"] as? [String: Any] ?? dict
            if let songID = dict["id"] as? String,
               (dict["type"] as? String == "songs" || dict["kind"] as? String == "song"),
               let title = attributes["name"] as? String, let artist = attributes["artistName"] as? String {
                let duration = (attributes["durationInMillis"] as? NSNumber).map { $0.doubleValue / 1000 }
                let song = Song(id: songID, title: title, artist: artist,
                                album: attributes["albumName"] as? String ?? attributes["collectionName"] as? String,
                                duration: duration)
                if songs[songID] == nil || (songs[songID]?.duration == nil && duration != nil) { songs[songID] = song }
                if let relationships = dict["relationships"] as? [String: Any],
                   let lyrics = relationships["syllable-lyrics"] as? [String: Any],
                   let data = lyrics["data"] as? [[String: Any]] {
                    for item in data {
                        let attr = item["attributes"] as? [String: Any] ?? [:]
                        if let xml = attr["ttml"] as? String { embedded.append((song, xml)) }
                        else if let xml = attr["ttmlLocalizations"] as? String { embedded.append((song, xml)) }
                        else if let localized = attr["ttmlLocalizations"] as? [String: String],
                                let key = preferredLanguages.lazy.compactMap({ language in localized.keys.sorted().first { $0.lowercased().hasPrefix(language.lowercased().prefix(2)) } }).first ?? localized.keys.sorted().first,
                                let xml = localized[key] { embedded.append((song, xml)) }
                    }
                }
            }
            for value in dict.values { collectSongs(value, into: &songs, embedded: &embedded, depth: depth + 1) }
        } else if let values = object as? [Any] {
            for value in values { collectSongs(value, into: &songs, embedded: &embedded, depth: depth + 1) }
        }
    }
}
