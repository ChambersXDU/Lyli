import AppKit
import LyliCore
import SwiftUI

@MainActor
struct OverlayTextSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {

        VStack(spacing: 0) {
            SettingsRow(icon: "character", title: "字体") {

                FontFamilyPicker(selection: $settings.fontFamilyName)
            }
            CardDivider()

            SettingsRow(icon: "bold", title: "粗细") {
                Picker("", selection: $settings.overlayFontWeight) {
                    ForEach(OverlayFontWeight.allCases, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .labelsHidden()

                .pickerStyle(.menu)
                .fixedSize()
            }
            CardDivider()
            SettingsRow(icon: "textformat.size", title: "字号") {
                HStack(spacing: 8) {

                    SteppedSlider(value: Binding(
                        get: { settings.fontSize },
                        set: { newValue in

                            guard newValue != settings.fontSize else { return }
                            settings.fontSize = newValue
                        }
                    ), in: 14...36, step: 1)
                        .frame(width: 150)
                    Text(String(format: "%@pt", "\(Int(settings.fontSize))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            CardDivider()

            SettingsRow(
                icon: "sparkles",
                title: "卡拉OK效果"
            ) {
                Toggle("", isOn: $settings.overlayLyricsKaraoke)
            }

            CardDivider()
            SettingsRow(icon: "paintbrush", title: "文字颜色") {
                ColorPicker("", selection: Binding(
                    get: { settings.foregroundColor },
                    set: { settings.foregroundColorHex = $0.hexStringWithAlpha }
                ), supportsOpacity: false)
            }
            CardDivider()
            SettingsRow(icon: "pencil.and.outline", title: "文字描边") {
                Toggle("", isOn: $settings.textStrokeEnabled)
            }
            if settings.textStrokeEnabled {
                CardDivider()
                SettingsSubRow(title: "描边颜色") {
                    ColorPicker("", selection: Binding(
                        get: { settings.textStrokeColor },
                        set: { settings.textStrokeColorHex = $0.hexStringWithAlpha }
                    ), supportsOpacity: true)

                }
            }
        }

        .animation(.default, value: settings.textStrokeEnabled)
    }
}

@MainActor
struct OverlayLayoutSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {

            SettingsRow(icon: "rectangle.grid.1x2", title: "双行显示") {
                Toggle("", isOn: $settings.showNextLinePreview)
            }
            CardDivider()

            SettingsRow(
                icon: "text.alignleft",
                title: "对齐方式"
            ) {

                OverlayAlignmentSegmentedControl(selection: $settings.overlayDuetAlignmentOverride)
            }
        }
    }
}

@MainActor
struct OverlayAlignmentSegmentedControl: View {
    @Binding var selection: OverlayDuetAlignmentOverride

    static func label(for option: OverlayDuetAlignmentOverride) -> String {
        switch option {
        case .automatic: return "自动"
        case .center: return "居中"
        case .leading: return "左对齐"
        case .trailing: return "右对齐"
        }
    }

    var body: some View {

        HStack(spacing: 2) {
            ForEach(OverlayDuetAlignmentOverride.allCases, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(Self.label(for: option))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(minWidth: 56)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )

        .fixedSize()
    }
}

@MainActor
struct OverlayBackgroundSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "rectangle.fill", title: "背景颜色") {
                ColorPicker("", selection: Binding(
                    get: { settings.backgroundColor },
                    set: { settings.backgroundColorHex = $0.hexStringWithAlpha }
                ), supportsOpacity: true)

            }

            CardDivider()

            SettingsSubRow(title: "毛玻璃背景") {
                Toggle("", isOn: $settings.overlayBackgroundGlass)
            }
        }
    }
}

@MainActor
struct OverlayThemeSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {

            SettingsRow(icon: "swatchpalette", title: "配色主题") {
                Menu(Self.currentThemeLabel) {
                    ForEach(ColorTheme.builtInPresets) { theme in
                        themeItem(theme)
                    }
                    if !settings.customColorThemes.isEmpty {
                        Divider()
                        ForEach(settings.customColorThemes) { theme in
                            themeItem(theme)
                        }
                    }
                }
                .fixedSize()
            }
            CardDivider()
            OverlayCustomThemeRows()
        }
    }

    private func themeItem(_ theme: ColorTheme) -> some View {
        Button(theme.name) { theme.apply(to: settings) }
    }

    static func currentColors(_ settings: AppSettings) -> ColorTheme {
        ColorTheme(
            name: "",
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        )
    }

    static var currentThemeLabel: String {
        let settings = AppSettings.shared
        let current = currentColors(settings)
        let all = ColorTheme.builtInPresets + settings.customColorThemes
        return all.first { $0.hasSameColors(as: current) }?.name ?? "自定义"
    }
}

private struct OverlayInlineConfirmRow<Content: View>: View {
    var title: String?
    var message: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 6) {
                if let title, !title.isEmpty {
                    Text(title).font(.system(size: 13))
                }
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) { content() }
                    .settingsGlassButtons()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsRowMetrics.textLeadingInset - 12)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

@MainActor
struct OverlayCustomThemeRows: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var isNaming = false
    @State private var newThemeName = ""

    @State private var pendingDeletion: ColorTheme.ID?

    private var trimmedName: String {
        newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "square.stack", title: "我的配色主题") {
                Button("存为新主题…") {
                    newThemeName = ""

                    pendingDeletion = nil
                    isNaming = true
                }
            }
            if isNaming {
                CardDivider()
                OverlayInlineConfirmRow(
                    message: "会把当前的文字颜色、背景颜色、描边颜色存成一个可以随时再套用的主题"
                ) {
                    TextField("主题名称", text: $newThemeName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)

                        .onSubmit { saveTheme() }
                    Button("保存") { saveTheme() }
                        .disabled(trimmedName.isEmpty)
                    Button("取消") { isNaming = false }
                }
            }
            ForEach(settings.customColorThemes) { theme in
                CardDivider()
                if pendingDeletion == theme.id {

                    OverlayInlineConfirmRow(
                        title: theme.name,
                        message: String(format: "「%@」删除后无法恢复", theme.name)
                    ) {

                        Button("删除", role: .destructive) {
                            settings.customColorThemes.removeAll { $0.id == theme.id }
                            pendingDeletion = nil
                        }
                        .foregroundStyle(.red)
                        .tint(.red)
                        Button("取消") { pendingDeletion = nil }
                    }
                } else {
                    SettingsSubRow(title: theme.name) {
                        HStack(spacing: 10) {

                            Image(nsImage: theme.swatchImage())
                            Button("套用") { theme.apply(to: settings) }
                            Button {
                                isNaming = false
                                pendingDeletion = theme.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .animation(.default, value: isNaming)
        .animation(.default, value: pendingDeletion)
    }

    private func saveTheme() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        settings.customColorThemes.append(ColorTheme(
            name: name,
            foregroundColorHex: settings.foregroundColorHex,
            backgroundColorHex: settings.backgroundColorHex,
            textStrokeEnabled: settings.textStrokeEnabled,
            textStrokeColorHex: settings.textStrokeColorHex
        ))
        newThemeName = ""
        isNaming = false
    }
}

@MainActor
enum OverlayStyleDefaults {
    static func restoreTextAndColors() {
        let settings = AppSettings.shared

        settings.fontFamilyName = AppSettings.defaultFontFamilyName
        settings.fontSize = AppSettings.defaultFontSize

        settings.overlayFontWeight = AppSettings.defaultOverlayFontWeight
        settings.foregroundColorHex = ColorTheme.defaultTheme.foregroundColorHex
        settings.backgroundColorHex = ColorTheme.defaultTheme.backgroundColorHex

        settings.overlayBackgroundGlass = false
        settings.textStrokeEnabled = ColorTheme.defaultTheme.textStrokeEnabled
        settings.textStrokeColorHex = ColorTheme.defaultTheme.textStrokeColorHex
    }
}

@MainActor
enum OverlayStyleSummary {

    static var text: String {
        let settings = AppSettings.shared
        return fontText(family: settings.fontFamilyName, weight: settings.overlayFontWeight, size: Int(settings.fontSize))
    }

    static func fontText(family: String, weight: OverlayFontWeight, size: Int) -> String {
        let sizeText = String(format: "%@pt", "\(size)")
        return "\(FontFamilyPicker.displayName(for: family)) \(weight.displayName) \(sizeText)"
    }

    static var theme: String {
        OverlayThemeSettingsRows.currentThemeLabel
    }

    static var background: String {
        let settings = AppSettings.shared
        if settings.overlayBackgroundGlass { return "毛玻璃" }
        return AppSettings.backgroundVisible(hex: settings.backgroundColorHex, glass: false)
            ? "纯色" : "透明"
    }

    static var layout: String {
        let settings = AppSettings.shared
        let lines = settings.showNextLinePreview ? "双行" : "单行"
        let alignment = OverlayAlignmentSegmentedControl.label(for: settings.overlayDuetAlignmentOverride)
        return "\(lines) · \(alignment)"
    }
}

