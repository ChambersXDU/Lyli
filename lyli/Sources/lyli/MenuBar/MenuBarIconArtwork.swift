import AppKit

@MainActor
enum MenuBarIconArtwork {
    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()
}
