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

    // 按下时抓住的是哪个手柄：这是「拖不动」最容易出错的一环，单独测。
    @Test func honoursCornersEdgesInsideAndOutside() {
        let size = CGSize(width: 200, height: 100)
        let box = [0.2, 0.2, 0.6, 0.6]
        #expect(CropGeometry.handle(at: CGPoint(x: 40, y: 20), box: box, size: size, freeform: true) == .topLeft)
        #expect(CropGeometry.handle(at: CGPoint(x: 160, y: 20), box: box, size: size, freeform: true) == .topRight)
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 20), box: box, size: size, freeform: true) == .top)
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 50), box: box, size: size, freeform: true) == .inside)
        #expect(CropGeometry.handle(at: CGPoint(x: 10, y: 90), box: box, size: size, freeform: true) == .draw)
        // 框外拖动一律重新画，锁了比例也照样能拖。
        #expect(CropGeometry.handle(at: CGPoint(x: 10, y: 90), box: box, size: size, freeform: false) == .draw)
        // 一进裁切页框是整张画面：这时框内拖动必须当成重新画，否则怎么拖都没反应。
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 50), box: [0, 0, 1, 1], size: size, freeform: true) == .draw)
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 50), box: [0, 0, 1, 1], size: size, freeform: false) == .draw)
    }

    @Test func draggingInsideMovesWithoutChangingSize() {
        let size = CGSize(width: 200, height: 100)
        let start = [0.2, 0.2, 0.5, 0.5]
        let moved = CropGeometry.dragged(start: start, handle: .inside, from: CGPoint(x: 100, y: 50),
                                         to: CGPoint(x: 140, y: 70), size: size, freeform: true)
        #expect(abs(moved[0] - 0.4) < 0.0001 && abs(moved[1] - 0.4) < 0.0001)
        #expect(abs(moved[2] - 0.5) < 0.0001 && abs(moved[3] - 0.5) < 0.0001)
        // 移出画面会被挡住，不会跑到照片外面。
        let clamped = CropGeometry.dragged(start: start, handle: .inside, from: .zero,
                                           to: CGPoint(x: 400, y: 300), size: size, freeform: true)
        #expect(clamped[0] + clamped[2] <= 1 && clamped[1] + clamped[3] <= 1)
    }

    @Test func draggingCornerResizesAndDrawingReplacesBox() {
        let size = CGSize(width: 200, height: 100)
        let start = [0.2, 0.2, 0.5, 0.5]
        let resized = CropGeometry.dragged(start: start, handle: .bottomRight, from: CGPoint(x: 140, y: 70),
                                           to: CGPoint(x: 180, y: 90), size: size, freeform: true)
        #expect(abs(resized[0] - 0.2) < 0.0001 && abs(resized[1] - 0.2) < 0.0001)
        #expect(abs(resized[2] - 0.7) < 0.0001 && abs(resized[3] - 0.7) < 0.0001)
        let drawn = CropGeometry.dragged(start: start, handle: .draw, from: CGPoint(x: 20, y: 10),
                                         to: CGPoint(x: 60, y: 30), size: size, freeform: true)
        #expect(abs(drawn[0] - 0.1) < 0.0001 && abs(drawn[2] - 0.2) < 0.0001)
    }

    @Test func rotatingAndFlippingCarriesTheBoxAlong() {
        #expect(CropGeometry.rotated([0, 0, 0.5, 0.5], quarter: 1) == [0.5, 0, 0.5, 0.5])
        #expect(CropGeometry.rotated([0, 0, 0.5, 0.5], quarter: 4) == [0, 0, 0.5, 0.5])
        let mirrored = CropGeometry.flipped([0.1, 0.2, 0.3, 0.4], axis: "h")
        #expect(abs(mirrored[0] - 0.6) < 0.0001 && abs(mirrored[1] - 0.2) < 0.0001)
        let turned = CropGeometry.flipped([0.1, 0.2, 0.3, 0.4], axis: "v")
        #expect(abs(turned[0] - 0.1) < 0.0001 && abs(turned[1] - 0.4) < 0.0001)
    }

    @Test func aspectChangeStaysInsideTheOldBox() {
        let box = CropGeometry.centered([0.9, 0.9], around: [0.05, 0.05])
        #expect(box[0] >= 0 && box[1] >= 0 && box[0] + box[2] <= 1 && box[1] + box[3] <= 1)
        #expect(CropGeometry.snappedAngle(0.2) == 0)
        #expect(abs(CropGeometry.snappedAngle(3.44) - 3.4) < 0.0001)
    }
}
