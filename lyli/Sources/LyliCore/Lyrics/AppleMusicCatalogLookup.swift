import Foundation

public struct AppleMusicCatalogSong: Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: Double?

    public init(id: String, title: String, artist: String, album: String? = nil, duration: Double? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Resolves public song metadata for IDs already present in local lyric responses.
/// No Music credentials or signed requests are used, and no lyrics are downloaded.
actor AppleMusicCatalogLookup {
    static let shared = AppleMusicCatalogLookup()
    private var songs: [String: AppleMusicCatalogSong] = [:]
    private var pending: [String: Task<[AppleMusicCatalogSong], Never>] = [:]
    private var attempted: [String: Date] = [:]

    func lookup(_ ids: [String]) async -> [AppleMusicCatalogSong] {
        let ids = Array(Set(ids.filter { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })).sorted()
        let missing = ids.filter { songs[$0] == nil && Date().timeIntervalSince(attempted[$0] ?? .distantPast) >= 120 }
        if !missing.isEmpty {
            let batch = Array(missing.prefix(160))
            let key = batch.joined(separator: ",")
            let task: Task<[AppleMusicCatalogSong], Never>
            if let running = pending[key] { task = running }
            else {
                task = Task { await Self.fetch(batch) }
                pending[key] = task
            }
            let results = await task.value
            pending[key] = nil
            for id in batch { attempted[id] = Date() }
            for song in results { songs[song.id] = song }
        }
        return ids.compactMap { songs[$0] }
    }

    private static func fetch(_ ids: [String]) async -> [AppleMusicCatalogSong] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "id", value: ids.joined(separator: ",")),
                                .init(name: "country", value: "cn"), .init(name: "entity", value: "song")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        let requested = Set(ids)
        return results.compactMap { item in
            guard item["kind"] as? String == "song", let id = item["trackId"] as? NSNumber,
                  requested.contains(id.stringValue), let title = item["trackName"] as? String,
                  let artist = item["artistName"] as? String else { return nil }
            return AppleMusicCatalogSong(id: id.stringValue, title: title, artist: artist,
                album: item["collectionName"] as? String,
                duration: (item["trackTimeMillis"] as? NSNumber).map { $0.doubleValue / 1_000 })
        }
    }
}
