import Foundation
import Testing
@testable import PhotoEdit

@Suite struct CropGeometryTests {
    @Test func drawsFreelyInEitherDirectionAndClampsToPhoto() throws {
        let first = try #require(CropGeometry.drawn(from: CGPoint(x: 80, y: 90), to: CGPoint(x: 20, y: 10), size: CGSize(width: 100, height: 100)))
        #expect(abs(first[0] - 0.2) < 0.00001 && abs(first[1] - 0.1) < 0.00001)
        #expect(abs(first[2] - 0.6) < 0.00001 && abs(first[3] - 0.8) < 0.00001)
        let bounded = try #require(CropGeometry.drawn(from: CGPoint(x: 20, y: 10), to: CGPoint(x: 130, y: 120), size: CGSize(width: 100, height: 100)))
        #expect(bounded[0] + bounded[2] == 1 && bounded[1] + bounded[3] == 1)
        #expect(CropGeometry.drawn(from: .zero, to: .zero, size: CGSize(width: 100, height: 100)) == nil)
    }
    @Test func lockedCornerMaintainsRatioAndOppositeCorner() {
        let start = [0.1, 0.2, 0.6, 0.4]
        let result = CropGeometry.locked(current: [0.2, 0.25, 0.5, 0.35], start: start, handle: "topLeft")
        #expect(abs(result[2] / result[3] - 1.5) < 0.00001)
        #expect(abs(result[0] + result[2] - 0.7) < 0.00001)
        #expect(abs(result[1] + result[3] - 0.6) < 0.00001)
    }
    @Test func lockedEdgeStaysInsideImage() {
        let start = [0.25, 0.1, 0.5, 0.8]
        let result = CropGeometry.locked(current: [0.25, 0.1, 0.75, 0.8], start: start, handle: "right")
        #expect(abs(result[2] / result[3] - 0.625) < 0.00001)
        #expect(result[0] >= 0 && result[1] >= 0 && result[0] + result[2] <= 1 && result[1] + result[3] <= 1)
    }
}
