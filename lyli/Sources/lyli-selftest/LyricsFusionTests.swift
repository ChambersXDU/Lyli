import Foundation
import LyliCore

func runLyricsFusionTests() {
    let texts = ["春風吹過，山與海", "星光落在你的肩", "我們唱著同一首歌", "等到明天再相見", "晴空照亮了遠方", "我們唱著同一首歌", "回家的路不再長", "把這一刻放心上"]
    func time(_ i: Int) -> Int { 10_000 + i * 8_000 }
    let lrc = texts.enumerated().flatMap { i, text in
        [String(format: "[%02d:%02d.000]%@", time(i) / 60_000, time(i) / 1_000 % 60, text),
         String(format: "[%02d:%02d.000]", (time(i) + 6_000) / 60_000, (time(i) + 6_000) / 1_000 % 60)]
    }.joined(separator: "\n")
    let tr = "[00:10.000]translation one\n[00:34.000]translation fallback"
    let official = LyricsCandidate(source: "appleMusic", lyrics: lrc, translation: tr,
        duration: 80, title: "Song", artist: "Artist")
    func donor(omitting: Set<Int> = [], replacing: [Int: String] = [:], shifts: [Int: Int] = [:],
               title: String = "Song", duration: Double = 80, overrun: Int? = nil) -> LyricsCandidate {
        let rows = texts.enumerated().compactMap { i, raw -> String? in
            if omitting.contains(i) { return nil }
            let mutable = NSMutableString(string: replacing[i] ?? raw) as CFMutableString
            CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
            let value = (mutable as String).replacingOccurrences(of: "，", with: "")
            let start = time(i) + (shifts[i] ?? 300)
            let chunks = Array(value).enumerated().map { j, c in
                "(\(start + j * 350),\(overrun == i ? 800 : 350),0)\(c)"
            }.joined()
            return "[\(start),\(value.count * 350)]" + chunks
        }.joined(separator: "\n")
        return LyricsCandidate(source: "kugou", lyrics: lrc, wordTiming: rows,
            duration: duration, title: title, artist: "Artist")
    }
    let full = LyricsFusion.fuse(official: official, donor: donor())
    expectEqual(full?.matchedLines, 8, "繁简标点与恒定小偏移允许融合")
    expectEqual(full?.source, "kugou")
    expectEqual(LyricsFusion.donorSource(in: full?.wordTiming ?? ""), "kugou")
    let engine = LyricsSyncEngine()
    _ = engine.load(lyrics: lrc, lyricsTr: tr, lyricsYRC: full?.wordTiming ?? "")
    for i in texts.indices {
        expectEqual(engine.currentLine(at: time(i) + 1)?.plainText, texts[i], "逐字原文必须保持官方字形和标点")
        expectEqual(engine.currentLine(at: time(i) + 1)?.words?.first?.startMs, time(i), "逐字重新锚定官方行")
        expectEqual(engine.currentLine(at: time(i) + 6_001), nil, "官方清屏不被逐字覆盖")
    }
    expectEqual(engine.currentLine(at: time(0) + 1)?.translation, "translation one")

    let partial = LyricsFusion.fuse(official: official, donor: donor(omitting: [2], replacing: [3: "等到后天再相见"]))
    expectEqual(partial?.matchedLines, 6, "缺行与文字差异仅回退相应行")
    _ = engine.load(lyrics: lrc, lyricsTr: tr, lyricsYRC: partial?.wordTiming ?? "")
    for i in texts.indices {
        expectEqual(engine.currentLine(at: time(i) + 1)?.plainText, texts[i], "任何官方行都不能丢失")
        expectEqual(engine.currentLine(at: time(i) + 1)?.words != nil, ![2, 3].contains(i))
    }
    expectEqual(engine.currentLine(at: time(3) + 1)?.translation, "translation fallback")
    expectEqual(engine.allLines(idPrefix: "hybrid").count, 8)
    // A missing repeated chorus must not borrow timing from its later occurrence.
    let missingChorus = LyricsFusion.fuse(official: official, donor: donor(omitting: [2]))
    expectEqual(YRCParser.parse(missingChorus?.wordTiming ?? "").contains { $0.timeMs == time(2) }, false)
    expectEqual(YRCParser.parse(missingChorus?.wordTiming ?? "").contains { $0.timeMs == time(5) }, true)
    expectEqual(LyricsFusion.fuse(official: official, donor: donor(title: "Song (Live)")) == nil, true)
    expectEqual(LyricsFusion.fuse(official: official, donor: donor(duration: 86)) == nil, true)
    expectEqual(LyricsFusion.fuse(official: official, donor: donor(shifts: [7: 4_000])) == nil, true, "尾部漂移拒绝整个版本")
    expectEqual(LyricsFusion.fuse(official: official, donor: donor(omitting: [0, 1, 3, 4, 6])) == nil, true)
    let repeated = LyricsCandidate(source: "appleMusic", lyrics: (0..<8).map {
        String(format: "[00:%02d.000]相同副歌", 10 + $0 * 5)
    }.joined(separator: "\n"), title: "Song", artist: "Artist")
    expectEqual(LyricsFusion.fuse(official: repeated, donor: donor()) == nil, true, "没有独立锚点不能猜重复段落")
    let huge = LyricsCandidate(source: "kugou", lyrics: lrc,
        wordTiming: "[10000,100](10000,9223372036854775807,0)a(10001,1,0)b\n[20000,100](20000,1,0)c(20001,1,0)d",
        title: "Song", artist: "Artist")
    expectEqual(LyricsFusion.fuse(official: official, donor: huge) == nil, true)
    let normalRows = YRCParser.parse(donor().wordTiming ?? "")
    func encode(_ rows: [LyricLineWords]) -> String {
        rows.map { row in
            "[\(row.timeMs),2000]" + row.words.map { "(\($0.startMs),\($0.durationMs),0)\($0.text)" }.joined()
        }.joined(separator: "\n")
    }
    let joined = LyricLineWords(timeMs: normalRows[0].timeMs, words: normalRows[0].words + normalRows[1].words)
    let mergedDonor = LyricsCandidate(source: "kugou", lyrics: lrc,
        wordTiming: encode([joined] + Array(normalRows.dropFirst(2))), title: "Song", artist: "Artist")
    let splitResult = LyricsFusion.fuse(official: official, donor: mergedDonor)
    expectEqual(splitResult?.matchedLines, 8, "其他源一行对应官方两行时按已有词边界拆分")
    let head = normalRows[0]
    let half = head.words.count / 2
    let firstHalf = LyricLineWords(timeMs: head.timeMs, words: Array(head.words.prefix(half)))
    let secondHalf = LyricLineWords(timeMs: head.words[half].startMs, words: Array(head.words.dropFirst(half)))
    let splitDonor = LyricsCandidate(source: "kugou", lyrics: lrc,
        wordTiming: encode([firstHalf, secondHalf] + Array(normalRows.dropFirst())), title: "Song", artist: "Artist")
    expectEqual(LyricsFusion.fuse(official: official, donor: splitDonor)?.matchedLines, 8, "其他源两行对应官方一行时可合并")
    let cut = head.words.count - 1
    let crosses = LyricLineWords(timeMs: joined.timeMs, words: [
        LyricWord(startMs: joined.timeMs, durationMs: 350, text: joined.words.prefix(cut + 2).map(\.text).joined()),
        LyricWord(startMs: joined.words[cut + 2].startMs, durationMs: 350, text: joined.words.dropFirst(cut + 2).map(\.text).joined())])
    let unsafeSplit = LyricsCandidate(source: "kugou", lyrics: lrc,
        wordTiming: encode([crosses] + Array(normalRows.dropFirst(2))), title: "Song", artist: "Artist")
    let refusedSplit = LyricsFusion.fuse(official: official, donor: unsafeSplit)
    expectEqual(refusedSplit?.matchedLines, 6, "官方分行切在来源词块内部时不猜插值")
    expectEqual(YRCParser.parse(refusedSplit?.wordTiming ?? "").contains { $0.timeMs == time(0) }, false)
    let badDurationRows = normalRows.enumerated().map { index, row in
        index != 3 ? row : LyricLineWords(timeMs: row.timeMs, words: row.words.enumerated().map { k, word in
            LyricWord(startMs: word.startMs, durationMs: k == row.words.count - 1 ? 6_000 : word.durationMs, text: word.text)
        })
    }
    let spills = LyricsCandidate(source: "kugou", lyrics: lrc, wordTiming: encode(badDurationRows), title: "Song", artist: "Artist")
    expectEqual(LyricsFusion.fuse(official: official, donor: spills)?.matchedLines, 7, "词尾超出官方清屏时回退该行")
    let existing = LyricsCandidate(source: "appleMusic", lyrics: lrc, wordTiming: full?.wordTiming,
        title: "Song", artist: "Artist")
    expectEqual(LyricsFusion.fuse(official: existing, donor: donor()) == nil, true, "原有官方逐字不被覆盖")
}
