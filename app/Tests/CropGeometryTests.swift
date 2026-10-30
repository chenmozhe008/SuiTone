import Testing
@testable import PhotoEdit

@Suite struct CropGeometryTests {
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
