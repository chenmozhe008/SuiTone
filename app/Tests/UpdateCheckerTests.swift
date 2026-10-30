import Foundation
import Testing
@testable import PhotoEdit

@Suite struct UpdateCheckerTests {
    @Test func versionComparisonUsesNumericComponents() {
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        #expect(!UpdateChecker.isNewer("1.9.2", than: "1.10.0"))
        #expect(!UpdateChecker.isNewer("1.0.0-beta", than: "1.0.0"))
    }

    @Test func acceptsOnlyProjectReleaseAndTrustedDownload() throws {
        let chip = UpdateChecker.isAppleSilicon ? "AppleSilicon" : "Intel"
        let obj: [String: Any] = ["tag_name": "v1.2.0", "html_url": "https://github.com/chenmozhe008/SuiTone/releases/tag/v1.2.0", "body": "## 更新内容\n- 修复预览", "assets": [["name": "SuiTone-1.2.0-\(chip).zip", "browser_download_url": "https://github.com/chenmozhe008/SuiTone/releases/download/v1.2.0/SuiTone-1.2.0-\(chip).zip", "digest": "sha256:" + String(repeating: "a", count: 64)]]]
        let release = try #require(UpdateChecker.parse(JSONSerialization.data(withJSONObject: obj)))
        #expect(release.version == "1.2.0" && release.asset != nil && release.notes == ["修复预览"])
        var wrong = obj; wrong["html_url"] = "https://example.com/release"
        #expect(UpdateChecker.parse(try JSONSerialization.data(withJSONObject: wrong)) == nil)
        wrong = obj; wrong["prerelease"] = true
        #expect(UpdateChecker.parse(try JSONSerialization.data(withJSONObject: wrong)) == nil)
        wrong = obj; wrong["assets"] = [["name": "SuiTone-1.2.0-\(chip).zip", "browser_download_url": "https://example.com/file.zip"]]
        #expect(UpdateChecker.parse(try JSONSerialization.data(withJSONObject: wrong))?.asset == nil)
        wrong = obj; wrong["assets"] = [["name": "SuiTone-1.2.0-\(chip).zip", "browser_download_url": "https://github.com/chenmozhe008/SuiTone/releases/download/v1.2.0/file.zip"]]
        #expect(UpdateChecker.parse(try JSONSerialization.data(withJSONObject: wrong))?.asset == nil)
    }
}
