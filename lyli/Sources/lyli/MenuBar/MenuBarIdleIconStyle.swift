import AppKit
import SwiftUI

@MainActor
enum MenuBarIdleIconStyle: String, CaseIterable, Identifiable {
    case note
    case noteList
    case waveform
    case mic
    case tuningfork
    case pianokeys
    case disc

    var id: Self { self }

    var displayName: String {
        switch self {
        case .note: return "音符"
        case .noteList: return "歌词"
        case .waveform: return "声波"
        case .mic: return "麦克风"
        case .tuningfork: return "音叉"
        case .pianokeys: return "钢琴"
        case .disc: return "唱片"
        }
    }

    var image: NSImage {
        let symbol: String
        switch self {
        case .note: symbol = "music.note"
        case .noteList: symbol = "music.note.list"
        case .waveform: symbol = "waveform"
        case .mic: symbol = "music.mic"
        case .tuningfork: symbol = "tuningfork"
        case .pianokeys: symbol = "pianokeys"
        case .disc: symbol = "opticaldisc"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }
}

@MainActor
struct MenuBarIdleIconPicker: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 5) {
            ForEach(MenuBarIdleIconStyle.allCases) { style in
                Button {
                    settings.menuBarIdleIconStyle = style
                } label: {
                    Image(nsImage: style.image)
                        .renderingMode(.template)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(settings.menuBarIdleIconStyle == style
                                      ? Color.accentColor.opacity(0.9)
                                      : Color.secondary.opacity(0.10)))
                        .foregroundStyle(settings.menuBarIdleIconStyle == style ? .white : .primary)
                }
                .buttonStyle(.plain)
                .help(style.displayName)
            }
        }
    }
}
