import AppKit
import LyliCore
import SwiftUI

@MainActor
struct MenuBarPreviewBar: View {

    @ObservedObject private var settings = AppSettings.shared

    @ObservedObject private var menuBarAppearance = MenuBarAppearanceStore.shared
    @State private var line: SyncedLyricLine?

    @State private var anchor: ProgressAnchor?
    @State private var pausedPositionMs: Int?
    @State private var lyricsOffsetMs = 0
    @State private var isPlayingNow = false

    private var fullText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return "这里是一句歌词示例"
    }

    private var secondaryKind: LyricSecondaryLine { settings.menuBarSecondaryLine }
    private var twoRows: Bool { secondaryKind.showsSecondaryRow }
    private var fullyPlayed: Bool { line != nil && (line?.words?.isEmpty ?? true) }

    private var mainFont: NSFont { MenuBarMarqueeRenderer.mainFont(for: fullText, twoRows: twoRows) }

    private var secondaryText: String? {
        guard twoRows else { return nil }
        if let line, let text = line.plainText, !text.isEmpty {
            return secondaryKind.secondaryText(currentLine: line,
                                               nextLineText: PlaybackCoordinator.shared.nextLineText)
        }
        return secondaryKind.displayName
    }

    private func adaptiveWindowWidth(for visible: String) -> CGFloat {
        let mainW = MenuBarMarqueeRenderer.width(of: visible, font: mainFont)
        guard twoRows else { return mainW }
        let secondaryW = secondaryText.map {
            MenuBarMarqueeRenderer.width(of: $0, font: MenuBarMarqueeRenderer.doubleRowSecondaryFont)
        } ?? 0
        return min(settings.menuBarLyricsWidth, max(mainW, secondaryW))
    }

    private var rowsHeight: CGFloat {
        twoRows ? MenuBarLyricRows.buttonHeight : MenuBarMarqueeRenderer.lineHeight
    }

    private var karaokeFillPath: [MenuBarMarquee.KaraokeFillPoint]? {
        guard settings.menuBarLyricsKaraoke,
              let line, let words = line.words, !words.isEmpty,
              line.plainText == fullText else { return nil }
        let path = MenuBarMarquee.karaokeFillPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: mainFont))
        return path.isEmpty ? nil : path
    }

    private var followReadingPath: [MenuBarMarquee.KaraokeFillPoint]? {
        guard let line, let words = line.words, !words.isEmpty,
              line.plainText == fullText else { return nil }
        let path = MenuBarMarquee.followReadingPath(
            words: words, wordEndXs: MenuBarMarqueeRenderer.wordEndXs(for: words, font: mainFont))
        return path.isEmpty ? nil : path
    }

    private var karaokePositionMs: Int? {
        let raw = anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
        return raw.map { $0 + lyricsOffsetMs }
    }

    private var previewIconBadge: MenuBarScrollingLabel.IconBadge? {
        let position = settings.menuBarLyricsIconPosition
        guard position != .off else { return nil }
        return MenuBarScrollingLabel.IconBadge(position: position)
    }

    private var reservedIconWidth: CGFloat {
        MenuBarProgressIcon.reservedWidth(enabled: previewIconBadge != nil)
    }

    private var progressPositionMs: Int? {
        anchor?.extrapolatedPositionMs(now: Date()) ?? pausedPositionMs
    }

    private var progressDurationMs: Int? {
        [anchor?.durationMs, PlaybackCoordinator.shared.currentDurationMs]
            .compactMap { $0 }.first { $0 > 0 }
    }

    private var previewTextColor: Color {
        guard fullyPlayed else { return Color(nsColor: .labelColor) }
        return Color(nsColor: MenuBarScrollingLabel.fillColor(
            hex: settings.menuBarLyricsFillColorHex,
            darkMenuBar: menuBarAppearance.isDark))
    }

    private var presentation: MenuBarMarqueeRenderer.Presentation {
        MenuBarMarqueeRenderer.presentation(
            for: fullText, windowWidth: settings.menuBarLyricsWidth,

            dwellSeconds: line == nil ? nil : PlaybackCoordinator.shared.currentLineDwellSeconds,

            leadInSeconds: 0,
            widthMode: settings.menuBarLyricsWidthMode,
            font: mainFont)
    }

    static var cardHeight: CGFloat { 24 }
    static let previewHeight: CGFloat = 250

    private var stageHeight: CGFloat { Self.previewHeight }

    var body: some View {
        let p = presentation
        return stage(p)
            .frame(maxWidth: .infinity)
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }

        .onReceive(PlaybackCoordinator.shared.$anchor) { anchor = $0 }
        .onReceive(PlaybackCoordinator.shared.$pausedPositionMs) { pausedPositionMs = $0 }
        .onReceive(PlaybackCoordinator.shared.$currentLyricsOffsetMs) { lyricsOffsetMs = $0 }
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow) { isPlayingNow = $0 }
        .accessibilityHidden(true)
    }

    private func stage(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        ZStack(alignment: .top) {
            desktopSurface
            menuBarStrip(p)
        }
            .frame(height: stageHeight, alignment: .top)
            .frame(maxWidth: .infinity)

            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            .environment(\.colorScheme, menuBarAppearance.colorScheme)
    }

    private var desktopSurface: some View {
        ZStack(alignment: .top) {
            if let wallpaper = DesktopWallpaperSample.image {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .frame(height: stageHeight, alignment: .top)
                    .clipped()
            } else {

                Color(nsColor: .textColor).opacity(0.14)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func menuBarStrip(_ p: MenuBarMarqueeRenderer.Presentation) -> some View {
        HStack(spacing: 0) {

            Image(systemName: "apple.logo")
                .font(.system(size: 16))
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
                .padding(.leading, 12)

            Spacer(minLength: 12)
            lyricsSlot(p)

                .padding(.horizontal, 3)

            HStack(spacing: 11) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text(Date(), style: .time)
            }
            .font(Font(MenuBarMarqueeRenderer.font))
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
            .padding(.leading, 14)
            .padding(.trailing, 12)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)

        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private func lyricsSlot(_ presentation: MenuBarMarqueeRenderer.Presentation) -> some View {
        switch presentation {
        case .text(let visible):

            if visible == fullText, karaokeFillPath != nil || previewIconBadge != nil || twoRows {
                let w = adaptiveWindowWidth(for: visible)
                MenuBarScrollingLabel.Representable(
                    text: visible, windowWidth: w, pacing: nil, fillPath: karaokeFillPath,
                    fullyPlayed: fullyPlayed, followPath: followReadingPath,
                    karaokePositionMs: karaokePositionMs,
                    karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow,
                    icon: previewIconBadge, progressPositionMs: progressPositionMs,
                    progressDurationMs: progressDurationMs,
                    secondaryText: secondaryText, secondaryKind: secondaryKind)
                    .frame(width: w + reservedIconWidth, height: rowsHeight)
            } else {
                Text(visible)
                    .font(Font(MenuBarMarqueeRenderer.font))
                    .foregroundStyle(previewTextColor)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: MenuBarMarqueeRenderer.lineHeight)
            }
        case .fixed(let text, let windowWidth, let pacing):
            MenuBarScrollingLabel.Representable(
                text: text, windowWidth: windowWidth, pacing: pacing,
                fillPath: karaokeFillPath, fullyPlayed: fullyPlayed,
                followPath: followReadingPath, karaokePositionMs: karaokePositionMs,
                karaokeRate: anchor?.rate ?? 0, karaokePlaying: isPlayingNow,
                icon: previewIconBadge, progressPositionMs: progressPositionMs,
                progressDurationMs: progressDurationMs,
                secondaryText: secondaryText, secondaryKind: secondaryKind)
                .frame(width: windowWidth + reservedIconWidth, height: rowsHeight)
        }
    }
}
