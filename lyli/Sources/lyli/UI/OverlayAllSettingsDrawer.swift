import LyliCore
import SwiftUI

@MainActor
struct OverlaySettingsList: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            themeGroup
            CardDivider()
            textGroup
            CardDivider()
            backgroundGroup
            CardDivider()
            layoutGroup
            CardDivider()
            widthRow
            CardDivider()
            behaviorGroup
            placementGroup
            CardDivider()
            resetRow
        }
    }

    private var themeGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("主题"))
            CardDivider()
            OverlayThemeSettingsRows()
        }
    }

    private var backgroundGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("背景"))
            CardDivider()
            OverlayBackgroundSettingsRows()
        }
    }

    private var textGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("文字"))
            CardDivider()
            OverlayTextSettingsRows()
        }
    }

    private var layoutGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("排版"))
            CardDivider()
            OverlayLayoutSettingsRows()
        }
    }

    private var behaviorGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("行为"))
            CardDivider()
            OverlayBehaviorSettingsRows()
        }
    }

    private var placementGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("位置"))
            CardDivider()
            OverlayPlacementSettingsRows()
        }
    }

    private var widthRow: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
            HStack(spacing: 8) {

                SteppedSlider(value: Binding(
                    get: { settings.overlayWidth },
                    set: { newValue in

                        guard newValue != settings.overlayWidth else { return }
                        settings.overlayWidth = newValue

                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setWidth(newValue)
                        }
                    }
                ), in: 300...1400, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"), "\(Int(settings.overlayWidth))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: L10n.t("恢复默认")
        ) {
            Button(L10n.t("恢复")) { OverlayStyleDefaults.restoreTextAndColors() }
        }
    }
}
