import Foundation

public enum LyliIdentity {
    public struct Resolved: Equatable {

        public let displayName: String

        public let bundleIdentifier: String

        public let configDirName: String
        public let appLogFileName: String

        public let urlScheme: String

    }

    public static let current = Resolved(
        displayName: "Lyli",
        bundleIdentifier: "com.chambersxdu.lyli",
        configDirName: "lyli",
        appLogFileName: "lyli-app.log",
        urlScheme: "lyli"
    )

    public static var displayName: String { current.displayName }
    public static var bundleIdentifier: String { current.bundleIdentifier }
    public static var configDirName: String { current.configDirName }
    public static var urlScheme: String { current.urlScheme }
}

public enum LyliPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var configDir: URL { home.appendingPathComponent(".config/\(LyliIdentity.configDirName)") }

    public static func configFile(_ name: String) -> URL { configDir.appendingPathComponent(name) }

}

public enum LogFiles {
    private static var logsDir: URL { LyliPaths.home.appendingPathComponent("Library/Logs") }

    public static var appStderr: URL { logsDir.appendingPathComponent(LyliIdentity.current.appLogFileName) }
}
