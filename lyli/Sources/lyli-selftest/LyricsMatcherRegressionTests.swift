import Foundation
import LyliCore

private let query = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 180)
private let lyrics = "[00:10.00]one two\n[00:20.00]three four\n[02:50.00]five six"
private let wordTiming = "[10000,1000](10000,1000,0)one two\n[20000,1000](20000,1000,0)three four\n[170000,1000](170000,1000,0)five six"

private func candidate(_ source: String, title: String = "Song", album: String = "Album",
                       body: String = lyrics, words: String? = nil, translation: String? = nil,
                       duration: Double? = 180) -> LyricsCandidate {
    LyricsCandidate(source: source, lyrics: body, translation: translation, wordTiming: words,
                    duration: duration, title: title, artist: "Artist", album: album)
}

private func points(_ match: LyricsMatch?, _ kind: String) -> Int {
    match?.terms.filter { $0.kind == kind }.reduce(0) { $0 + $1.points } ?? 0
}

func runLyricsMatcherRegressionTests() {
    let hinsQuery = LyricsQuery(title: "明明他已离开你", artist: "张敬轩", album: "Senses Inherited", duration: 180)
    let hins = LyricsCandidate(source: "qq", lyrics: lyrics, duration: 180,
        title: "明明他已離開妳", artist: "張敬軒", album: "Senses Inherited")
    let hinsMatch = LyricsMatcher.rank([hins], for: hinsQuery).first
    expectEqual(hinsMatch?.isRejected, false, "繁简歌手名不再被拒绝")
    expectEqual(points(hinsMatch, "titleMatch"), 120, "标题兼容繁简与妳/你")
    let longLyrics = "[00:10.00]天空的云慢慢走过山丘我们抬起头\n[00:20.00]风吹过河流带来很久以前的问候\n[02:50.00]你的笑容留在每个清晨温暖心中"
    for (original, translated, artist, decorated) in [
        ("Clouds", "云朵", "林小雨", "Lynn林小雨"),
        ("River", "河流", "陈小舟", "Boat陈小舟"),
        ("星光", "Starlight", "Lunar Echo", "Lunar Echo"),
        ("Fly", "飞", "吕彦良", "Matt吕彦良")
    ] {
        let request = LyricsQuery(title: original, artist: artist, album: "Shared Album", duration: 180)
        let a = LyricsCandidate(source: "qq", lyrics: longLyrics, duration: 180, title: translated, artist: decorated, album: "Shared Album")
        let b = LyricsCandidate(source: "netease", lyrics: longLyrics, duration: 181, title: translated, artist: artist, album: "Shared Album")
        let matching = LyricsMatcher.rank([a, b], for: request)
        expectEqual(matching.first?.isRejected, false, "通用目录证据支持任意翻译歌名")
        expectEqual(points(matching.first, "titleMatch"), 80)
        expectEqual(matching.first?.consensusPeers.count, 1)
        expectEqual(LyricsMatcher.rank([a], for: request).first?.terms.first?.kind, "rejectUnconfirmedIdentity")
        let duplicate = LyricsCandidate(source: "qq", lyrics: longLyrics, translation: "text", duration: 180, title: translated, artist: decorated, album: "Shared Album")
        expectEqual(LyricsMatcher.rank([a, duplicate], for: request).allSatisfy(\.isRejected), true, "同来源重复不能证明别名")
        for conflict in [
            LyricsCandidate(source: "third", lyrics: longLyrics, duration: 180, title: translated, artist: "Other Artist", album: "Shared Album"),
            LyricsCandidate(source: "third", lyrics: longLyrics, duration: 180, title: translated, artist: artist, album: "Other Album"),
            LyricsCandidate(source: "third", lyrics: longLyrics, duration: 190, title: translated, artist: artist, album: "Shared Album"),
            LyricsCandidate(source: "third", lyrics: longLyrics, duration: 180, title: translated + " (Live)", artist: artist, album: "Shared Album")
        ] {
            expectEqual(LyricsMatcher.rank([a, conflict], for: request).allSatisfy(\.isRejected), true, "身份冲突不能参与译名验证")
        }
        let ambiguous = LyricsCandidate(source: "third", lyrics: lyrics, duration: 180, title: "Another Track", artist: artist, album: "Shared Album")
        expectEqual(LyricsMatcher.rank([a, b, ambiguous], for: request).allSatisfy(\.isRejected), true, "同专辑同曲长存在冲突正文时不猜测")
    }
    expectEqual(LyricsMatcher.titlesMatch("Haruka", "ハルカ (Haruka)"), true, "日文假名双语标题也提供名称证据")
    expectEqual(LyricsMatcher.titlesMatch("Clouds", "云朵 (Clouds)"), true, "双语标题自身提供名称证据")
    expectEqual(LyricsMatcher.titlesMatch("Clouds", "云朵 (Live)"), false)
    expectEqual(LyricsMatcher.titlesMatch("Fly", "Flying (Live)"), false, "英文词缀不视为同名")
    expectEqual(LyricsMatcher.normalizedArtist("Hebe田馥甄"), "田馥甄")
    expectEqual(LyricsMatcher.normalizedArtist("John / 王宇") == "王宇", false, "英文与中文合作歌手分隔符不被归一化吞掉")
    expectEqual(LyricsMatcher.normalizedArtist("王宇 / Alex王宇") == "王宇", false, "合作歌手不合并成单人")

    let translatedRequest = LyricsQuery(title: "Original Name", artist: "Artist", album: "Album", duration: 180)
    let translatedA = candidate("a", title: "Translated Name", body: longLyrics)
    let translatedB = candidate("b", title: "Translated Name", body: longLyrics)
    let conflictingReference = candidate("appleMusic", title: "Original Name", body: "[00:10.00]这一段是另外一种录音完全不同的歌词内容\n[00:20.00]第二段继续说明这是不同语言录音的歌词内容\n[02:50.00]最后一段同样包含足够长的文字用来检测歌词差异")
    expectEqual(LyricsMatcher.rank([translatedA, translatedB, conflictingReference], for: translatedRequest)
        .filter { $0.source != "appleMusic" }.allSatisfy(\.isRejected), true, "官方正文冲突不能被外部译名多数覆盖")
    let albumVariant = LyricsMatcher.rank([candidate("original"), candidate("different", album: "Other Album", body: "[00:10.00]unrelated track first line\n[00:20.00]unrelated track second line\n[02:50.00]unrelated track last line", words: wordTiming)], for: query)
    expectEqual(albumVariant.first?.source, "original", "明确专辑版本正文冲突时逐字奖励不能抢占")
    expectEqual(points(albumVariant.last, "wordTimingOverride"), -400)
    let duplicatedSource = LyricsMatcher.rank([
        candidate("a"), candidate("b"), candidate("b", album: "Compilation"),
        candidate("b", translation: "[00:10.00]译文"),
    ], for: query).first { $0.source == "a" }
    expectEqual(duplicatedSource?.consensusPeers, ["b"], "一个来源的多份候选只提供一次印证")
    expectEqual(points(duplicatedSource, "consensus"), 150)
    let independentSources = LyricsMatcher.rank([candidate("a"), candidate("b"), candidate("c")], for: query)
    expectEqual(independentSources.first?.consensusPeers.count, 2)
    expectEqual(points(independentSources.first, "consensus"), 250)

    let unrelatedPeer = LyricsMatcher.rank([candidate("a"), candidate("b", title: "Unrelated", album: "Other Album")], for: query)
        .first { $0.source == "a" }
    expectEqual(unrelatedPeer?.consensusPeers, [], "不同歌曲不能给当前歌词提供印证")
    let scrambled = "[00:10.00]six five\n[00:20.00]four three\n[02:50.00]two one"
    let reordered = LyricsMatcher.rank([candidate("a"), candidate("b", body: scrambled)], for: query)
    expectEqual(reordered.map(\.consensusPeers), [[], []], "单词集合相同不能证明正文相似")
    let punctuation = "[00:10.00]One, two!\n[00:20.00]Three four.\n[02:50.00]Five six"
    let punctuationMatches = LyricsMatcher.rank([candidate("a"), candidate("b", body: punctuation)], for: query)
    expectEqual(punctuationMatches.map(\.consensusPeers), [["b"], ["a"]], "标点大小写差异不妨碍印证")
    let chinese = "[00:10.00]天空中有一朵云\n[00:20.00]我在这里等着你\n[02:50.00]我们一起走回家"
    let chinesePunctuation = "[00:10.00]天空中有一朵云，\n[00:20.00]我在这里等着你。\n[02:50.00]我们一起走回家！"
    let chineseMatches = LyricsMatcher.rank([
        candidate("a", body: chinese), candidate("b", body: chinesePunctuation),
    ], for: query)
    expectEqual(chineseMatches.map(\.consensusPeers), [["b"], ["a"]], "中文标点差异不妨碍印证")

    let invalidWords = candidate("a", words: "[broken]")
    expectEqual(invalidWords.hasWordTiming, false, "无法解析的逐字数据回退到 LRC")
    expectEqual(invalidWords.wordTiming, nil)
    let invalidRank = LyricsMatcher.rank([candidate("a"), candidate("a", words: "[broken]")], for: query)
    expectEqual(invalidRank.count, 1)
    expectEqual(points(invalidRank.first, "wordTiming"), 0)
    let partialWords = candidate("a", words: "[10000,1000](10000,1000,0)one two")
    expectEqual(partialWords.hasWordTiming, false, "只有一行的残缺逐字轨不能领取整首的加分")
    let decreasingWords = "[10000,1000](10500,500,0)one (10000,500,0)two\n[20000,1000](20000,1000,0)three four"
    expectEqual(candidate("a", words: decreasingWords).hasWordTiming, false, "句内时间倒退的逐字轨回退")
    let validRank = LyricsMatcher.rank([candidate("a", words: wordTiming)], for: query)
    expectEqual(validRank.first?.candidate.hasWordTiming, true)
    expectEqual(points(validRank.first, "wordTiming"), 400, "正常逐字歌词保留原有优先级")

    let outro = "[00:10.00]one two\n[00:20.00]three four\n[01:50.00]five six"
    let padded = outro + "\n[03:00.00]\n[03:00.00]作词：作者"
    let clean = LyricsMatcher.rank([candidate("a", body: outro)], for: query).first
    let withPadding = LyricsMatcher.rank([candidate("a", body: padded)], for: query).first
    expectEqual(clean?.score, withPadding?.score, "空时间戳和署名不能给歌词增加分数")
    expectEqual(LyricsMatcher.endTime(candidate("a", body: padded)), 110)
    let nearEnd = LyricsMatcher.rank([candidate("a")], for: query).first
    expectEqual(clean?.score, nearEnd?.score, "已知曲长一致时，长尾奏不降低匹配分")
    let paddedUnknown = LyricsMatcher.rank([candidate("a", body: padded, duration: nil)], for: query).first
    let cleanUnknown = LyricsMatcher.rank([candidate("a", body: outro, duration: nil)], for: query).first
    expectEqual(paddedUnknown?.score, cleanUnknown?.score, "未知曲长的补充判断也忽略无效末尾")
    let zeroDuration = LyricsMatcher.rank([candidate("a", duration: 0)], for: query).first
    let absentDuration = LyricsMatcher.rank([candidate("a", duration: nil)], for: query).first
    expectEqual(zeroDuration?.score, absentDuration?.score, "来源的零曲长视为未知，不是冲突")

    let variants = [candidate("same", album: "Compilation", body: outro), candidate("same"),
                    candidate("same", words: wordTiming), candidate("same", translation: "[00:10.00]译文")]
    let forward = LyricsMatcher.rank(variants + [variants[1]], for: query)
    let reverse = LyricsMatcher.rank(Array(variants.reversed()), for: query)
    expectEqual(forward.count, 4, "保留专辑、时间轴、逐字和译文不同的候选，只删除完全重复项")
    expectEqual(forward, reverse, "接口返回顺序不影响候选排序")
    expectEqual(forward.first?.candidate.wordTiming, wordTiming)
    let tied = [candidate("same"), candidate("same", body: lyrics.replacingOccurrences(of: "00:20", with: "00:30"))]
    expectEqual(LyricsMatcher.rank(tied, for: query), LyricsMatcher.rank(Array(tied.reversed()), for: query),
                "相同来源同分时也保持确定的排序")

    let karaoke = LyricsMatcher.rank([candidate("original"), candidate("karaoke", album: "Song Karaoke", words: wordTiming)], for: query)
    expectEqual(karaoke.first?.source, "original", "伴奏专辑不能靠逐字奖励压过原版")
    expectEqual(points(karaoke.last, "wordTimingOverride"), -400)
    let liveQuery = LyricsQuery(title: "Song (Live)", artist: "Artist", album: "Live at Venue", duration: 180)
    let live = candidate("live", title: "Song (Live)", album: "Live at Venue")
    let liveVsStudio = LyricsMatcher.rank([live, candidate("studio", words: wordTiming)], for: liveQuery)
    expectEqual(liveVsStudio.first?.source, "live", "明确现场版查询优先有现场信息的候选")
    let liveAcoustic = LyricsMatcher.rank([live, candidate("acoustic", title: "Song (Live Acoustic)", album: "Live at Venue", words: wordTiming)], for: liveQuery)
    expectEqual(liveAcoustic.first?.source, "live", "同有 Live 标签不代表录音版本相同")
    let chineseLive = LyricsMatcher.rank([candidate("original"), candidate("live", title: "Song现场版", words: wordTiming)], for: query)
    expectEqual(chineseLive.first?.source, "original", "识别没有空格的中文现场标记")
    let remaster = LyricsMatcher.rank([candidate("original"), candidate("remaster", title: "Song (2014 Remastered)", words: wordTiming)], for: query)
    expectEqual(remaster.first?.source, "remaster", "重制标记不妨碍采用正常逐字歌词")
    expectEqual(points(remaster.first, "versionTags"), 0)
    expectEqual(points(remaster.first, "wordTimingOverride"), 0)
    let unknownLive = LyricsMatcher.rank([candidate("studio", words: wordTiming)], for: liveQuery)
    expectEqual(unknownLive.first?.isRejected, false, "只有版本信息不完整的可用候选时继续提供歌词")
    expectEqual(points(unknownLive.first, "wordTimingOverride"), 0)
    let studioAlbum = LyricsMatcher.rank([candidate("studio", album: "Live Through This")],
                                        for: LyricsQuery(title: "Song", artist: "Artist", duration: 180))
    expectEqual(points(studioAlbum.first, "versionTags"), 0, "专辑名中的普通 Live 单词不当作现场标记")
    let literalLiveQuery = LyricsQuery(title: "I Want to Live Forever", artist: "Artist", album: "Album", duration: 180)
    let literalLive = LyricsMatcher.rank([
        candidate("original", title: "I Want to Live Forever"),
        candidate("live", title: "I Want to Live Forever (Live)", words: wordTiming),
    ], for: literalLiveQuery)
    expectEqual(literalLive.first?.source, "original", "歌名中的普通 Live 单词不掩盖额外现场标记")
    expectEqual(points(literalLive.first, "versionTags"), 0)
    let unrelatedVersion = LyricsMatcher.rank([
        candidate("usable", words: wordTiming), candidate("unrelated", title: "Different Song"),
    ], for: LyricsQuery(title: "Song (Live)", artist: "Artist", duration: 180))
    expectEqual(points(unrelatedVersion.first { $0.source == "usable" }, "wordTimingOverride"), 0,
                "不同歌曲的版本信息不能撤掉唯一相关候选的逐字奖励")
    let priority = LyricsMatcher.rank([candidate("original"), candidate("karaoke", album: "Song Karaoke", words: wordTiming)],
                                     for: query, sourceOrder: ["karaoke", "original"], prioritizeSources: true)
    expectEqual(priority.first?.source, "karaoke", "用户明确选择的来源顺序仍然生效")
}
