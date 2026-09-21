import SwiftUI
import LyliCore

extension LyricSecondaryLine {
    var displayName: String {
        switch self {
        case .off: return "不显示"
        case .nextLine: return "下一句"
        case .translation: return "译文"
        case .romanization: return "罗马音"
        }
    }
}

struct MenuBarWidthRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(icon: "arrow.left.and.right", title: "最大宽度") {
            HStack(spacing: 8) {

                SteppedSlider(value: Binding(
                    get: { Double(settings.menuBarLyricsWidth) },
                    set: {

                        let quantized = CGFloat(($0 / 10).rounded() * 10)
                        guard quantized != settings.menuBarLyricsWidth else { return }
                        settings.menuBarLyricsWidth = quantized
                    }
                ), in: 80...600, step: 10)
                .frame(width: 150)
                Text(String(format: "%@pt", "\(Int(settings.menuBarLyricsWidth))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

extension MenuBarLyricsWidthMode {
    var displayName: String {
        switch self {
        case .fixed: return "固定"
        case .adaptive: return "自适应"
        }
    }
}

extension MenuBarLyricsIconPosition {

    var displayName: String {
        switch self {
        case .off: return "不显示"
        case .leading: return "左"
        case .trailing: return "右"
        }
    }
}

struct MenuBarLyricsIconRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "chart.bar.fill",
            title: "歌词旁的图标"
        ) {
            Picker("", selection: $settings.menuBarLyricsIconPosition) {
                ForEach(MenuBarLyricsIconPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

struct MenuBarTitleFallbackRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "music.note.list",
            title: "无歌词时显示歌名"
        ) {
            Toggle("", isOn: $settings.menuBarShowsTitleWhenNoLyrics)
        }
    }
}

@MainActor
enum MenuBarStyleDefaults {
    static func restoreDefaults() {
        let settings = AppSettings.shared

        settings.menuBarLyricsWidthMode = AppSettings.defaultMenuBarLyricsWidthMode
        settings.menuBarLyricsAlignment = AppSettings.defaultMenuBarLyricsAlignment
        settings.menuBarSecondaryLine = AppSettings.defaultMenuBarSecondaryLine
        settings.menuBarLyricsIconPosition = AppSettings.defaultMenuBarLyricsIconPosition

        settings.menuBarLyricsKaraoke = AppSettings.defaultMenuBarLyricsKaraoke
        settings.menuBarLyricsTextColorHex = AppSettings.defaultMenuBarLyricsTextColorHex
        settings.menuBarLyricsFillColorHex = AppSettings.defaultMenuBarLyricsFillColorHex

        settings.menuBarLyricsFontWeight = AppSettings.defaultMenuBarLyricsFontWeight
        settings.menuBarLyricsFontSize = AppSettings.defaultMenuBarLyricsFontSize

        settings.menuBarShowsTitleWhenNoLyrics = AppSettings.defaultMenuBarShowsTitleWhenNoLyrics
    }
}

struct MenuBarLayoutRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarWidthModeRow()
            CardDivider()
            MenuBarSecondaryLineRow()
            CardDivider()
            MenuBarLyricsIconRow()
        }
    }
}

struct MenuBarBehaviorRows: View {
    var body: some View {
        MenuBarTitleFallbackRow()
    }
}

struct MenuBarWidthModeRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "arrow.left.and.right.circle",
            title: "宽度模式"
        ) {
            Picker("", selection: $settings.menuBarLyricsWidthMode) {
                Text("固定").tag(MenuBarLyricsWidthMode.fixed)
                Text("自适应").tag(MenuBarLyricsWidthMode.adaptive)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }

        if settings.menuBarLyricsWidthMode == .fixed {
            CardDivider()
            MenuBarAlignmentRow()
        }
    }
}

struct MenuBarAlignmentRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.alignleft",
            title: "对齐方式"
        ) {

            LyricsAlignmentSegmentedControl(selection: $settings.menuBarLyricsAlignment,
                                            options: LyricsRestingAlignment.menuBarOptions)
        }
    }
}

struct MenuBarFontRows: View {
    var body: some View {
        VStack(spacing: 0) {
            MenuBarFontWeightRow()
            CardDivider()
            MenuBarFontSizeRow()
        }
    }
}

struct MenuBarSecondaryLineRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "text.append",
            title: "副行"
        ) {
            Picker("", selection: $settings.menuBarSecondaryLine) {
                ForEach(LyricSecondaryLine.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

struct MenuBarFontSizeRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "textformat.size",
            title: "字号"
        ) {

            if settings.menuBarSecondaryLine.showsSecondaryRow {
                Text("由副行决定")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    SteppedSlider(value: Binding(
                        get: { Double(MenuBarMarqueeRenderer.font.pointSize) },
                        set: { newValue in
                            let range = MenuBarMarqueeRenderer.fontSizeRange
                            let quantized = min(max(CGFloat(newValue.rounded()), range.lowerBound), range.upperBound)
                            let stored: CGFloat = quantized == MenuBarMarqueeRenderer.systemPointSize ? 0 : quantized
                            guard stored != settings.menuBarLyricsFontSize else { return }
                            settings.menuBarLyricsFontSize = stored
                        }
                    ), in: Double(MenuBarMarqueeRenderer.fontSizeRange.lowerBound)...Double(MenuBarMarqueeRenderer.fontSizeRange.upperBound), step: 1)
                        .frame(width: 150)
                    Text(String(format: "%@pt", "\(Int(MenuBarMarqueeRenderer.font.pointSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}

struct MenuBarFontWeightRow: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsRow(
            icon: "bold",
            title: "粗细"
        ) {
            Picker("", selection: $settings.menuBarLyricsFontWeight) {
                ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                    Text(weight.displayName).tag(weight)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

struct MenuBarColorRows: View {
    @ObservedObject private var settings = AppSettings.shared

    @ObservedObject private var menuBarAppearance = MenuBarAppearanceStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                icon: "text.word.spacing",
                title: "卡拉OK效果"
            ) {
                Toggle("", isOn: $settings.menuBarLyricsKaraoke)
            }
            CardDivider()
            SettingsRow(
                icon: "textformat",
                title: settings.menuBarLyricsKaraoke
                    ? "未唱到的颜色" : "文字颜色"
            ) {
                HStack(spacing: 8) {
                    if !settings.menuBarLyricsTextColorHex.isEmpty {
                        Button("跟随系统") { settings.menuBarLyricsTextColorHex = "" }
                    }

                    ColorPicker("", selection: Binding(
                        get: {
                            Color(nsColor: MenuBarScrollingLabel
                                .textColor(hex: settings.menuBarLyricsTextColorHex,
                                           highlighted: false)
                                .resolved(in: menuBarAppearance.appearance))
                        },
                        set: { settings.menuBarLyricsTextColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: false)
                }
            }

            if settings.menuBarLyricsKaraoke || settings.menuBarLyricsIconPosition != .off {
                CardDivider()
                SettingsRow(
                    icon: "paintpalette.fill",
                    title: "已唱到的颜色"
                ) {
                    HStack(spacing: 8) {
                        if !settings.menuBarLyricsFillColorHex.isEmpty {
                            Button("跟随系统") { settings.menuBarLyricsFillColorHex = "" }
                        }

                        ColorPicker("", selection: Binding(
                            get: {
                                Color(nsColor: MenuBarScrollingLabel
                                    .fillColor(hex: settings.menuBarLyricsFillColorHex,
                                               darkMenuBar: menuBarAppearance.isDark)
                                    .resolved(in: menuBarAppearance.appearance))
                            },
                            set: { settings.menuBarLyricsFillColorHex = $0.hexStringWithAlpha }
                        ), supportsOpacity: false)
                    }
                }
            }
        }
    }
}

struct MenuBarSettingsList: View {
    var body: some View {
        SettingsCard {
            group("布局") { MenuBarLayoutRows() }
            CardDivider()
            group("配色") { MenuBarColorRows() }
            CardDivider()
            group("字体") { MenuBarFontRows() }
            CardDivider()
            MenuBarWidthRow()
            CardDivider()
            group("行为") { MenuBarBehaviorRows() }
            CardDivider()
            resetRow
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Group {
            SettingsCardHeader(title: title)
            CardDivider()
            content()
        }
    }

    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: "恢复默认"
        ) {
            Button("恢复") { MenuBarStyleDefaults.restoreDefaults() }
        }
    }
}
