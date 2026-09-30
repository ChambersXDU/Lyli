import CoreGraphics
import Foundation

public enum MenuBarSlotPolicy {
    public static let accompanimentText = "● ● ●"

    public static func accompanimentFillPath(in gap: LyricsGapMarker,
                                              wordEndXs: [CGFloat]) -> [MenuBarMarquee.KaraokeFillPoint] {
        let words = (0..<3).map { index in
            let start = gap.startMs + (gap.endMs - gap.startMs) * index / 3
            let end = gap.startMs + (gap.endMs - gap.startMs) * (index + 1) / 3
            return SyncedLyricWord(text: index < 2 ? "● " : "●", startMs: start,
                                   durationMs: max(1, end - start))
        }
        return MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: wordEndXs)
    }

    public static let minimumShrinkPoints: CGFloat = 6

    public static let minimumWidenPoints: CGFloat = 6

    public static func skipsResize(
        currentLength: CGFloat, targetLength: CGFloat,
        dwellSeconds: Double?, quietSecs: Double
    ) -> Bool {
        let delta = targetLength - currentLength
        guard delta != 0 else { return false }
        let deadZone = delta > 0 ? minimumWidenPoints : minimumShrinkPoints
        if abs(delta) < deadZone { return true }
        guard let dwellSeconds else { return false }
        return dwellSeconds < quietSecs
    }

    public static func slotWidth(
        naturalWidth: CGFloat, upcomingWidth: CGFloat,
        isPlaceholder: Bool, maxWidth: CGFloat
    ) -> CGFloat {
        guard isPlaceholder else { return naturalWidth }
        return min(maxWidth, max(naturalWidth, upcomingWidth))
    }

    public static func displayText(
        lyricText: String, title: String, isPlaying: Bool, isAdBreak: Bool,
        showsTitleWhenNoLyrics: Bool, placeholderGlyph: String,
        hasStartedLyrics: Bool = false, isAccompaniment: Bool = false
    ) -> (text: String, isFallback: Bool)? {
        guard isPlaying else { return nil }
        if isAccompaniment || (hasStartedLyrics && lyricText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return (accompanimentText, false)
        }
        if !lyricText.isEmpty { return (lyricText, false) }
        guard showsTitleWhenNoLyrics, !isAdBreak else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (placeholderGlyph + " " + trimmed, true)
    }
}
