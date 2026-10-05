import Foundation
import LyliCore

func runSustainedWordGlowTests() {
    func word(_ text: String = "光", duration: Int = 2_000) -> SyncedLyricWord {
        SyncedLyricWord(text: text, startMs: 1_000, durationMs: duration)
    }
    func glow(_ ms: Int, _ value: SyncedLyricWord = word()) -> Double {
        KaraokeFill.sustainGlowIntensity(for: value, atMs: ms)
    }
    expectEqual(glow(999), 0.0)
    expectEqual(glow(1_000), 0.0)
    expectEqual(glow(3_000), 0.0)
    expectEqual(glow(3_001), 0.0)
    expectEqual(glow(1_600, word(duration: 1_199)), 0.0)
    expectEqual(glow(1_600, word(duration: 1_200)) > 0, true)
    expectEqual(glow(2_000, word("明亮")), 0.0, "中文按单字处理")
    expectEqual(glow(2_000, word("𠮷𠮷")), 0.0, "扩展汉字仍按单字处理")
    expectEqual(glow(2_000, word("光，")) > 0, true, "标点不改变单字单位")
    expectEqual(glow(2_000, word("不要把整句误判")), 0.0)
    expectEqual(glow(2_000, word("whole lyric line")), 0.0)
    expectEqual(glow(2_000, word("…")), 0.0)
    expectEqual(glow(2_000, word("   ")), 0.0)
    expectEqual(glow(2_000, word(" forever ")) > 0, true)
    expectEqual(glow(2_000, word(duration: Int.max)), 0.0)
    expectEqual(glow(Int.max), 0.0)
    expectEqual(glow(Int.min), 0.0)
    expectEqual(glow(1_050) < glow(1_200), true, "长音缓慢亮起")
    expectEqual(glow(2_800) > glow(2_950), true, "词尾淡出")
    let values = (0...4_000).map { glow($0) }
    expectEqual(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 0.6 }, true)
    expectEqual(zip(values, values.dropFirst()).allSatisfy { abs($0 - $1) < 0.01 }, true, "每毫秒连续且无硬闪")
    let beforeSeek = glow(1_500)
    _ = glow(2_950)
    expectEqual(glow(1_500), beforeSeek, "回拖即时跟随歌词时钟")
}

func runSustainedWordGlowBenchmark() {
    let words = (0..<32).map { index in
        SyncedLyricWord(text: index == 16 ? "光" : "词", startMs: index * 1_000,
                        durationMs: index == 16 ? 2_000 : 350)
    }
    let frames = 100_000
    var checksum = 0.0
    let start = DispatchTime.now().uptimeNanoseconds
    for frame in 0..<frames {
        for word in words {
            checksum += KaraokeFill.sustainGlowIntensity(for: word, atMs: 16_001 + frame % 1_999)
        }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print(String(format: "GLOW MATH: 32 words/frame, %d frames, %.3f us/frame, %.3f ms per second at 30fps; checksum %.1f", frames, elapsed / Double(frames) * 1_000, elapsed / Double(frames) * 30, checksum))
}
