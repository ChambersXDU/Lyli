import LyliCore
import SwiftUI

@MainActor
final class OverlayPreviewChrome: ObservableObject, OverlayChromeSource {
    let isHoveringForControls = false
    let isHoveringLyrics = false
    let isHoveringControlPill = false
    let hoveredControl: OverlayControlID? = nil
    let isDragArmed = false
    let showDragHint = false
    let transientHint: String? = nil
    let placementLockNotice: String? = nil
    let placementLockShakeTick = 0

    func controlsDidBecomeVisible() {}
}

@MainActor
struct OverlayDesktopPreview: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var chrome = OverlayPreviewChrome()
    @State private var contentHeight: CGFloat = 0

    private static let stageHeight: CGFloat = 250
    private static let minimumOverlayHeight: CGFloat = 120

    private var overlayHeight: CGFloat {
        min(max(Self.minimumOverlayHeight, ceil(contentHeight)), Self.stageHeight - 20)
    }

    private static var previewLine: OverlayPreviewLine {
        OverlayPreviewLine(
            line: SyncedLyricLine(
                translation: "这里是译文示例",
                mainText: "这里是一句歌词示例",
                words: nil,
                side: nil),
            nextLineText: "这里是下一句歌词示例")
    }

    var body: some View {
        GeometryReader { proxy in
            let stageWidth = proxy.size.width
            ZStack {
                OverlayDesktopSurface()
                    .frame(width: stageWidth, height: Self.stageHeight)
                    .clipped()

                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.14)

                LyricsOverlayView(
                    overlayController: chrome,
                    onContentHeightChange: { contentHeight = $0 },
                    showsDebugHUD: false,
                    previewLine: Self.previewLine)
                    .frame(width: settings.overlayWidth, height: overlayHeight, alignment: .top)
                    .clipped()
            }
            .frame(width: stageWidth, height: Self.stageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .frame(height: Self.stageHeight)
        .accessibilityHidden(true)
    }
}
