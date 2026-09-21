import Foundation

public enum LegalNoticeLinks {
    public static let repo = "https://github.com/ChambersXDU/Lyli"

    public static let thirdPartyLicensesOnGitHub = URL(string: repo + "/blob/main/THIRD_PARTY_LICENSES")!

    public static let licenseOnGitHub = URL(string: repo + "/blob/main/LICENSE")!

    public static var usageNoticeURL: URL {
        var components = URLComponents(string: repo)!
        components.path = "/ChambersXDU/Lyli/blob/main/README.md"
        components.fragment = "license"
        return components.url!
    }
}
