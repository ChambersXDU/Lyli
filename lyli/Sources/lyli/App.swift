import SwiftUI

@main
struct LyliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {

        Settings {
            SettingsView()
        }
        Window("歌词管理", id: "lyrics-manager") {
            LyricsManagerView()
        }

        Window("搜索歌词…", id: "lyrics-quick-search") {
            LyricsQuickSearchWindow()
        }

    }
}
