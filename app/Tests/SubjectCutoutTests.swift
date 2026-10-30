import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhotoEdit

@Suite struct SubjectCutoutTests {
    @Test func testSystemCutoutKeepsPersonAndRejectsBackground() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/distinct-samples-20261029/portrait.jpg")
        guard FileManager.default.fileExists(atPath: sample.path) else { /* 跳过：缺少公开人像样片 */ return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cutout-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let coverage = try SubjectCutout.cutout(image: sample, point: CGPoint(x: 0.42, y: 0.4), output: output)
        #expect(coverage > 0.05 && coverage < 0.9)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.alphaInfo == .premultipliedLast || image.alphaInfo == .last)
        #expect(throws: (any Error).self) {
            try SubjectCutout.cutout(image: sample, point: CGPoint(x: 0.02, y: 0.03), output: output)
        }
    }
}
