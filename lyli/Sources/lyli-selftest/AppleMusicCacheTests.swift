import Foundation
import LyliCore
import CSQLite

private let appleFixture = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:xml="http://www.w3.org/XML/1998/namespace">
<head><metadata><itunes:iTunesMetadata><itunes:translations>
<itunes:translation xml:lang="zh-Hans"><itunes:text for="L1">译文一</itunes:text><itunes:text for="L2">译文二</itunes:text></itunes:translation>
</itunes:translations></itunes:iTunesMetadata></metadata></head>
<body><div><p begin="1.250s" end="3s" itunes:key="L1"><span begin="1.250s" end="2s">one </span><span begin="2s" end="3s">two</span></p>
<p begin="00:00:05.000" end="00:00:06.000" itunes:key="L2"><span begin="5000ms" end="6000ms">second line</span></p></div></body></tt>
"""

func runAppleMusicCacheTests() {
    let parsed = AppleMusicTTMLParser.parse(appleFixture, preferredLanguages: ["zh-CN"])
    expectEqual(LRCParser.parse(parsed?.lyrics ?? "").filter { !$0.text.isEmpty }.map(\.timeMs), [1250, 5000], "Apple 精确保留毫秒行时间")
    expectEqual(YRCParser.parse(parsed?.wordTiming ?? "").first?.words, [
        LyricWord(startMs: 1250, durationMs: 750, text: "one "),
        LyricWord(startMs: 2000, durationMs: 1000, text: "two")
    ], "Apple span 时间未经逐字插值")
    expectEqual(LRCParser.parse(parsed?.translation ?? "").map(\.text), ["译文一", "译文二"], "Apple 按行 key 对齐翻译")
    expectEqual(parsed?.endMs, 6000)
    expectEqual(AppleMusicTTMLParser.parse("<tt><body><p>") == nil, true, "截断 XML 不产生歌词")
    expectEqual(AppleMusicTTMLParser.parse("<!DOCTYPE tt [<!ENTITY test SYSTEM 'file:///tmp/private'>]><tt/>") == nil, true, "不展开外部实体")
    let lineOnly = "<tt><body><p begin='1s' end='3s'>first</p><p begin='5s' end='6s'>second</p></body></tt>"
    expectEqual(AppleMusicTTMLParser.parse(lineOnly)?.wordTiming, nil, "整行 TTML 不伪造逐字时间")
    expectEqual(AppleMusicTTMLParser.parse("<tt><body><p begin='NaN' end='inf'>bad</p></body></tt>") == nil, true)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lyli-apple-cache-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
        let provider = AppleMusicCacheProvider(cacheDirectory: root)
        let query = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
        expectEqual(try provider.read(query).count, 0, "没有 Music 缓存时正常回退")
        let catalog: [String: Any] = ["resources": ["songs": ["123": ["id": "123", "type": "songs", "attributes": ["name": "Song", "artistName": "Artist", "albumName": "Album", "durationInMillis": 180_000]]]]]
        let lyrics: [String: Any] = ["status": "success", "ttml": appleFixture]
        func hex(_ object: Any) throws -> String { try JSONSerialization.data(withJSONObject: object).map { String(format: "%02X", $0) }.joined() }
        let schema = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER,request_key TEXT,time_stamp TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER,isDataOnFS INTEGER,receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1,'https://amp-api.music.apple.com/v1/catalog/cn/songs/123','2026-01-01');
        INSERT INTO cfurl_cache_receiver_data VALUES(1,0,X'\(try hex(catalog))');
        INSERT INTO cfurl_cache_response VALUES(2,'https://se2.itunes.apple.com/wa/ttmlLyrics?id=123','2026-01-02');
        INSERT INTO cfurl_cache_receiver_data VALUES(2,0,X'\(try hex(lyrics))');
        """
        let database = root.appendingPathComponent("Cache.db")
        let result = ProcessRunner.run("/usr/bin/sqlite3", [database.path, schema], timeout: 3)
        expectEqual(result?.succeeded, true)
        let original = try Data(contentsOf: database)
        let candidates = try provider.read(query)
        expectEqual(candidates.count, 1, "inline body 通过歌曲 ID 关联")
        expectEqual(candidates.first?.hasWordTiming, true)
        expectEqual(try Data(contentsOf: database), original, "读取前后 Cache.db 内容不变")
        expectEqual(try provider.read(LyricsQuery(title: "Song (Live)", artist: "Artist", album: "Album", duration: 180)).count, 0, "不混入现场版本")
        expectEqual(try provider.read(LyricsQuery(title: "Song", artist: "Someone", album: "Album", duration: 180)).count, 0, "不混入同名异歌手")
        expectEqual(try provider.read(LyricsQuery(title: "Song", artist: "Artist", album: "Other", duration: 180)).count, 0, "不混入不同专辑")
        expectEqual(try provider.read(LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 220)).count, 0, "不混入时长不符的版本")
        expectEqual(try provider.read(LyricsQuery(title: "Song", artist: "Artist")).count, 0, "没有专辑与时长证据时不猜测")
        var writer: OpaquePointer?
        expectEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
        expectEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let busyStarted = Date()
        do { _ = try provider.read(query); expectEqual(false, true, "写锁应回退") }
        catch { expectEqual(error is AppleMusicCacheProvider.CacheError, true) }
        expectEqual(Date().timeIntervalSince(busyStarted) < 1, true, "数据库忙时不长时间阻塞")
        sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
        sqlite3_close(writer)
        let embedded: [String: Any] = ["data": [["id": "456", "type": "songs", "attributes": ["name": "Embedded", "artistName": "Artist", "albumName": "Album", "durationInMillis": 180_000], "relationships": ["syllable-lyrics": ["data": [["attributes": ["ttmlLocalizations": ["en": appleFixture]]]]]]]]]
        _ = ProcessRunner.run("/usr/bin/sqlite3", [database.path, "INSERT INTO cfurl_cache_response VALUES(3,'https://amp-api.music.apple.com/v1/catalog/cn/songs/456?include=syllable-lyrics','2026-01-03'); INSERT INTO cfurl_cache_receiver_data VALUES(3,0,X'\(try hex(embedded))');"], timeout: 3)
        expectEqual(try provider.read(LyricsQuery(title: "Embedded", artist: "Artist", album: "Album", duration: 180)).first?.hasWordTiming, true, "catalog syllable-lyrics 内嵌逐字格式")
        let filename = UUID().uuidString
        try JSONSerialization.data(withJSONObject: lyrics).write(to: root.appendingPathComponent("fsCachedData/" + filename))
        _ = ProcessRunner.run("/usr/bin/sqlite3", [database.path, "UPDATE cfurl_cache_receiver_data SET isDataOnFS=1,receiver_data='\(filename)' WHERE entry_ID=2;"], timeout: 3)
        expectEqual(try provider.read(query).count, 1, "fsCachedData 大响应正文")
        _ = ProcessRunner.run("/usr/bin/sqlite3", [database.path, "UPDATE cfurl_cache_receiver_data SET receiver_data='../Cache.db' WHERE entry_ID=2;"], timeout: 3)
        expectEqual(try provider.read(query).count, 0, "拒绝缓存路径穿越")
        _ = ProcessRunner.run("/usr/bin/sqlite3", [database.path, "DROP TABLE cfurl_cache_receiver_data;"], timeout: 3)
        do { _ = try provider.read(query); expectEqual(false, true, "未知数据库结构应报告失败") }
        catch { expectEqual(error is AppleMusicCacheProvider.CacheError, true) }
    } catch {
        expectEqual(String(describing: error), "no error", "Apple 缓存测试 fixture 运行")
    }
}
