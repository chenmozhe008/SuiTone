import Foundation

enum AppIdentity {
    static let name = "随心修图"
    static let englishName = "SuiTone"
    static let windowTitle = "随心修图"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
}
