import Foundation
import Testing
@testable import PhotoEdit

@Suite struct CropGeometryTests {
    @Test func rotatedFrameStaysWithinPhotoAndSmallerFramesCanMoveFurther() {
        let source = CGSize(width: 1200, height: 800), angle = 20.0
        let canvas = CropGeometry.canvasSize(size: source, angle: angle)
        for flip in ["", "h", "v"] {
            for x in [-0.5, 0.0, 0.5, 1.0] {
                let box = CropGeometry.constrainCanvas([x, 0.3, 0.3, 0.25], size: source, angle: angle, flip: flip)
                let a = angle * .pi / 180, c = cos(a), s = sin(a)
                for px in [box[0], box[0] + box[2]] {
                    for py in [box[1], box[1] + box[3]] {
                        var dx = (px - 0.5) * canvas.width, dy = (py - 0.5) * canvas.height
                        if flip == "h" { dx = -dx }; if flip == "v" { dy = -dy }
                        #expect(abs(c * dx - s * dy) <= source.width / 2)
                        #expect(abs(s * dx + c * dy) <= source.height / 2)
                    }
                }
            }
        }
        let small = CropGeometry.constrainCanvas([0.8, 0.4, 0.15, 0.15], size: source, angle: angle, flip: "")
        let big = CropGeometry.constrainCanvas([0.8, 0.2, 0.6, 0.6], size: source, angle: angle, flip: "")
        #expect(small[0] + small[2] / 2 > big[0] + big[2] / 2)
    }

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
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 95), box: box, size: size, freeform: true) == .draw)
        // 框外拖动一律重新画，锁了比例也照样能拖。
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 95), box: box, size: size, freeform: false) == .draw)
        // 一进裁切页框是整张画面：这时框内拖动必须当成重新画，否则怎么拖都没反应。
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 50), box: [0, 0, 1, 1], size: size, freeform: true) == .draw)
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 50), box: [0, 0, 1, 1], size: size, freeform: false) == .draw)
    }

    @Test func fullFrameHandlesAndAccidentalDrag() {
        let size = CGSize(width: 400, height: 300), full = [0.0, 0.0, 1.0, 1.0]
        #expect(CropGeometry.handle(at: CGPoint(x: 0, y: 0), box: full, size: size, freeform: true) == .topLeft)
        #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 0), box: full, size: size, freeform: true) == .top)
        #expect(CropGeometry.handle(at: CGPoint(x: -20, y: -20), box: full, size: size, freeform: true) == .rotate)
        let resized = CropGeometry.dragged(start: full, handle: .topLeft, from: .zero, to: CGPoint(x: 40, y: 30), size: size, freeform: true)
        #expect(abs(resized[2] - 0.9) < 0.0001 && abs(resized[3] - 0.9) < 0.0001)
        let accidental = CropGeometry.dragged(start: full, handle: .draw, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 120), size: size, freeform: true)
        #expect(accidental == full)
        let deliberate = CropGeometry.dragged(start: full, handle: .draw, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 200), size: size, freeform: true)
        #expect(deliberate != full)
    }

    @Test func rotationDirectionAndWrapAcrossBoundary() {
        let center = CGPoint(x: 100, y: 100)
        #expect(abs(CropGeometry.rotationDelta(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 100, y: 200), center: center) - 90) < 0.001)
        let delta = CropGeometry.rotationDelta(from: CGPoint(x: 0, y: 101), to: CGPoint(x: 0, y: 99), center: center)
        #expect(delta > 0 && delta < 2)
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
                                         to: CGPoint(x: 60, y: 40), size: size, freeform: true)
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

/// 点「确定」之后的行为：留在裁切页，且不重复记历史。
@MainActor @Suite struct CropCommitTests {
    @MainActor private func fixture() -> WorkspaceStore {
        let store = WorkspaceStore()
        let imported = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg", thumbnail: "/thumb.png",
                                     original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: imported, assetID: "original")]
        store.currentID = "photo"
        store.inspectorTab = "crop"
        return store
    }

    @Test @MainActor func rotatingBackDoesNotAccumulateCropLoss() throws {
        let store = fixture()
        store.beginCrop()
        for angle in stride(from: 0.0, through: 30.0, by: 0.5) { store.straightenPreview(angle) }
        for angle in stride(from: 30.0, through: 0.0, by: -0.5) { store.straightenPreview(angle) }
        store.finishStraighten()
        let box = try #require(store.cropDraft)
        #expect(box[2] > 0.99 && box[3] > 0.99)
    }

    @Test @MainActor func rotatingAfterConfirmationReopensTheAppliedCrop() {
        let store = fixture()
        store.cropDraft = [0.1, 0.2, 0.7, 0.6]
        store.cropEditing = true
        store.finishCrop()
        #expect(!store.cropEditing)
        store.straightenPreview(-4)
        #expect(store.cropEditing)
        #expect(store.cropExpanded && store.cropDraft != nil)
        store.finishStraighten()
        store.finishCrop()
        store.applyAngle(-5)
        #expect(store.cropEditing)
        #expect(store.cropExpanded && store.cropDraft != nil)
    }

    @Test @MainActor func confirmingKeepsTheCropPageAndRecordsOnce() throws {
        let store = fixture()
        store.cropDraft = [0.2, 0.15, 0.5, 0.6]
        store.finishCrop()
        // 裁完还留在裁切页：想换页自己点上面的页签。
        #expect(store.inspectorTab == "crop")
        let written = try #require(store.current?.parameters.crop)
        #expect(zip(written, [0.2, 0.15, 0.5, 0.6]).allSatisfy { abs($0 - $1) < 0.0001 })
        let count = store.undoChanges.count
        #expect(count == 1)
        // 再点一次「确定」不该把历史堆满。
        store.finishCrop()
        #expect(store.undoChanges.count == count)
    }

    @Test @MainActor func straightenUpdatesDuringDragAndCreatesOneUndoStep() {
        let store = fixture()
        store.straightenPreview(-3)
        #expect(store.current?.parameters.angle == -3)
        store.straightenPreview(-5)
        #expect(store.current?.parameters.angle == -5)
        #expect(store.undoChanges.isEmpty)
        store.finishStraighten()
        #expect(store.undoChanges.count == 1)
        store.undo()
        #expect(store.current?.parameters.angle == 0)
        store.previewTask?.cancel()
    }

    @Test @MainActor func reenteringCropShowsTheCommittedBox() {
        let store = fixture()
        store.cropDraft = [0.1, 0.2, 0.3, 0.4]
        store.commitCrop()
        store.cropDraft = nil
        store.beginCrop()
        #expect(store.cropDraft == [0.1, 0.2, 0.3, 0.4])
    }

    /// 第二张照片：切过去时框不该沿用上一张的。
    @MainActor private func addSecond(_ store: WorkspaceStore) {
        let imported = ImportedPhoto(id: "photo2", path: "/second.jpg", name: "second.jpg", thumbnail: "/thumb2.png",
                                     original: "/source2.png", width: 1200, height: 800, similarTo: nil)
        store.photos.append(PhotoRecord(imported: imported, assetID: "original2"))
    }

    @Test @MainActor func switchingPhotoWithUnappliedCropAsksFirst() {
        let store = fixture()
        addSecond(store)
        store.cropEditing = true
        store.cropDraft = [0.2, 0.2, 0.5, 0.5]
        #expect(store.cropDirty)
        store.activate("photo2")
        // 还没答复：照片不换，问句挂着。
        #expect(store.currentID == "photo")
        #expect(store.cropSwitchPrompt)
        #expect(store.pendingCropSwitchTarget == "photo2")
    }

    @Test @MainActor func applyingThenSwitchingWritesCropAndResetsTheBox() throws {
        let store = fixture()
        addSecond(store)
        store.cropEditing = true
        store.cropDraft = [0.2, 0.2, 0.5, 0.5]
        store.activate("photo2")
        store.confirmCropSwitch(apply: true)
        #expect(store.currentID == "photo2")
        #expect(store.inspectorTab == "adjust")
        let written = try #require(store.photos.first?.parameters.crop)
        #expect(zip(written, [0.2, 0.2, 0.5, 0.5]).allSatisfy { abs($0 - $1) < 0.0001 })
        // 新照片没有裁切，框回到整张，不会把上一张的框带过来。
        #expect(store.cropDraft == [0, 0, 1, 1])
    }

    @Test @MainActor func discardingThenSwitchingLeavesThePhotoUntouched() {
        let store = fixture()
        addSecond(store)
        store.cropEditing = true
        store.cropDraft = [0.2, 0.2, 0.5, 0.5]
        store.activate("photo2")
        store.confirmCropSwitch(apply: false)
        #expect(store.currentID == "photo2")
        #expect(store.photos.first?.parameters.crop == nil)
    }

    @Test @MainActor func cancelKeepsThePhotoAndTheBox() {
        let store = fixture()
        addSecond(store)
        store.cropEditing = true
        store.cropDraft = [0.3, 0.3, 0.4, 0.4]
        store.activate("photo2")
        store.cancelCropSwitch()
        #expect(store.currentID == "photo")
        #expect(store.cropDraft == [0.3, 0.3, 0.4, 0.4])
        #expect(!store.cropSwitchPrompt)
    }

    /// 按「确定」之后，画面里的框必须收起来——留着的话，人会觉得点了没生效，
    /// 而且下一张照片一切换就会被当成「有未应用的裁切」弹窗。
    @Test @MainActor func confirmingHidesTheBox() {
        let store = fixture()
        store.beginCrop()
        store.cropDraft = [0.2, 0.15, 0.5, 0.6]
        #expect(store.cropEditing)
        store.finishCrop()
        #expect(!store.cropEditing)
        #expect(!store.cropDirty)
        #expect(!store.cropPreviewing)
        #expect(store.current?.parameters.crop == [0.2, 0.15, 0.5, 0.6])
    }

    /// 确定之后切照片：不该再弹「裁切还没应用」。
    @Test @MainActor func confirmedCropSwitchesWithoutAsking() {
        let store = fixture()
        addSecond(store)
        store.beginCrop()
        store.cropDraft = [0.2, 0.15, 0.5, 0.6]
        store.finishCrop()
        store.activate("photo2")
        #expect(store.currentID == "photo2")
        #expect(!store.cropSwitchPrompt)
        #expect(store.inspectorTab == "adjust")
        // 框跟着收起来，新照片上也不会画出上一张的框。
        #expect(!store.cropEditing)
    }

    /// 框跟已应用的一样，就不该拦人。
    @Test @MainActor func cleanCropSwitchesWithoutAsking() {
        let store = fixture()
        addSecond(store)
        store.cropEditing = true
        store.cropDraft = [0.1, 0.1, 0.4, 0.4]
        store.commitCrop()
        #expect(!store.cropDirty)
        store.activate("photo2")
        #expect(store.currentID == "photo2")
        #expect(!store.cropSwitchPrompt)
    }
}

/// 离开 AI 改图页：那一轮的选区和临时版本预览都要撤掉。
@MainActor @Suite struct AIEditExitTests {
    @MainActor private func fixture() -> WorkspaceStore {
        let store = WorkspaceStore()
        let imported = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg", thumbnail: "/thumb.png",
                                     original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: imported, assetID: "original")]
        store.currentID = "photo"
        store.inspectorTab = "aiedit"
        return store
    }

    @Test @MainActor func leavingDropsSelectionAndVersionPreview() {
        let store = fixture()
        store.selectionParts = [SelectionPart(box: [0.2, 0.2, 0.6, 0.6])]
        store.selectionOverlay = "/tmp/overlay.png"
        store.versionPreview = "/tmp/version.png"
        store.leaveAIEdit()
        #expect(store.selectionParts.isEmpty)
        #expect(store.selectionOverlay == nil)
        #expect(store.versionPreview == nil)
    }
}
