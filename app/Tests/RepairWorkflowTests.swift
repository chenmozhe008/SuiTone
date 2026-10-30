import Foundation
import Testing
@testable import PhotoEdit

@MainActor @Suite struct RepairWorkflowTests {
    @MainActor private func fixture() -> WorkspaceStore {
        let store = WorkspaceStore()
        let imported = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg", thumbnail: "/thumb.png",
            original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: imported, assetID: "original")]
        store.currentID = "photo"
        store.selectionBox = [0.2, 0.3, 0.4, 0.6]
        store.repairDraft = RepairDraft(photoID: "photo", sourceAssetID: "original", parameters: store.photos[0].parameters,
            operation: RemovalOperation(box: store.selectionBox!, classes: nil, keep: nil),
            resultAssetID: "repaired", beforePath: "/before.png", previewPath: "/after.png")
        return store
    }

    @Test @MainActor func testSelectingRegionShowsOutlineNotTintUntilAsked() async throws {
        let store = fixture()
        store.analysis = AnalysisResponse(regions: [:], overlays: ["sky": "/mask.png", "water": "/water.png"],
                                          cacheHit: true, analysisMs: 0, inferenceCount: 0)
        store.selectLocalRegion("sky")
        #expect(store.overlay.isEmpty && store.localRegion == "sky")
        store.showLocalOverlay("sky")
        try await Task.sleep(for: .milliseconds(90))
        #expect(store.overlay == "sky")  // 手动显示的染色不会自动消失
        store.selectLocalRegion("water")
        #expect(store.overlay.isEmpty && store.localRegion == "water" && store.localOutline == nil)
        store.selectLocalRegion(nil)
        #expect(store.localRegion == nil)
    }

    @Test @MainActor func testChatSelectionTransfersToRepair() {
        let store = fixture()
        store.repairDraft = nil; store.beginChatSelection()
        store.updateChatSelection(from: [0.1, 0.2], to: [0.5, 0.6])
        let expected = store.selectionBox
        store.finishRepairTransition(to: "repair")
        #expect(store.selectionBox == expected)
        #expect(store.repairTool == "box")
    }

    @Test @MainActor func testCancelLeavesPhotoAndHistoryUntouched() async {
        let store = fixture(), before = store.current!.snapshot
        #expect(store.controlsBlocked)
        store.cancelRepairPreview()
        #expect(store.current!.snapshot == before)
        #expect(store.undoChanges.isEmpty)
        #expect(store.repairDraft == nil)
        #expect(store.selectionBox == nil)
        #expect(!(store.controlsBlocked))
    }

    @Test @MainActor func testApplyCreatesOneUndoableChangeAndKeepsColorParameters() async {
        let store = fixture(), before = store.current!.snapshot
        store.applyRepairPreview()
        #expect(store.current!.assetID == "repaired")
        #expect(store.current!.operations.count == 1)
        #expect(store.current!.parameters == before.parameters)
        #expect(store.current!.previewPath == "/after.png")
        #expect(store.undoChanges.count == 1)
        #expect(store.repairDraft == nil)
        store.undo()
        store.previewTask?.cancel()
        #expect(store.current!.snapshot.assetID == before.assetID)
        #expect(store.current!.operations == before.operations)
        store.redo()
        store.previewTask?.cancel()
        #expect(store.current!.assetID == "repaired")
        #expect(store.current!.operations.count == 1)
    }

    @Test @MainActor func testStalePreviewCannotReplaceNewerPhotoEdits() async {
        let store = fixture()
        store.photos[0].parameters.exposure = 0.7
        store.applyRepairPreview()
        #expect(store.current!.assetID == "original")
        #expect(store.current!.parameters.exposure == 0.7)
        #expect(store.undoChanges.isEmpty)
        #expect(store.repairDraft == nil)
    }

    @Test @MainActor func testInvalidAndTinySelectionsCannotStartRepair() async {
        let store = fixture()
        for box in [[0.1], [0.2, 0.3, 0.2, 0.6], [-0.1, 0.2, 0.4, 0.6], [0.2, 0.3, Double.nan, 0.6]] {
            store.selectionBox = box
            #expect(!(store.validRepairSelection))
        }
        store.selectionBox = [0.1, 0.2, 0.4, 0.6]
        #expect(store.validRepairSelection)
    }

    @Test @MainActor func testChatBoxDoesNotReuseOldBrushOrObjectSelection() {
        let store = fixture()
        store.repairTool = "brush"; store.repairMode = "keepSky"
        store.repairStrokes = [[[0.2, 0.3], [0.4, 0.5]]]
        store.repairPoint = [0.4, 0.4]
        store.beginChatSelection()
        store.updateChatSelection(from: [0.8, 0.7], to: [0.3, 0.2])
        #expect(store.selectionBox == [0.3, 0.2, 0.8, 0.7])
        let operation = store.removalOperation(store.selectionBox!)
        #expect(operation.strokes == nil && operation.point == nil && operation.keep == nil)
        store.clearRepairSelection()
        #expect(store.selectionBox == nil && store.repairStrokes.isEmpty && store.repairPoint == nil)
    }

    @Test @MainActor func testMovingRepairSelectionToChatPreservesItsShape() {
        let store = fixture()
        store.repairDraft = nil
        store.repairTool = "brush"
        store.repairStrokes = [[[0.2, 0.3], [0.4, 0.5]]]
        store.finishRepairTransition(to: "chat")
        let operation = store.removalOperation(store.selectionBox!)
        #expect(operation.strokes == [[[0.2, 0.3], [0.4, 0.5]]])
        #expect(operation.radius == store.brushSize)
        store.finishRepairTransition(to: "adjust")  // 换功能不丢选区
        #expect(store.selectionBox != nil && !store.repairStrokes.isEmpty)
        store.finishRepairTransition(to: "cutout")  // 抠图是单独点选，清掉
        #expect(store.selectionBox == nil && store.repairStrokes.isEmpty)
    }

    @Test @MainActor func testSelectionPartsAddSubtractUndoAndFeedRemoval() {
        let store = fixture()
        store.repairDraft = nil; store.inspectorTab = "selection"
        store.repairTool = "box"; store.selectionSubtract = true
        store.selectionDraftBox = [0.1, 0.1, 0.5, 0.5]; store.commitSelectionPart()
        #expect(store.selectionParts.isEmpty)  // 没有添加过时不能先减
        store.selectionSubtract = false
        store.selectionDraftBox = [0.1, 0.1, 0.5, 0.5]; store.commitSelectionPart()
        store.repairTool = "brush"; store.selectionSubtract = true
        store.repairStrokes = [[[0.3, 0.3], [0.35, 0.35]]]; store.commitSelectionPart()
        #expect(store.selectionParts.count == 2 && store.selectionParts[1].subtract && store.repairStrokes.isEmpty)
        #expect(store.selectionBox == [0.1, 0.1, 0.5, 0.5])  // 外接框只算添加的部分
        let operation = store.removalOperation(store.selectionBox!)
        #expect(operation.parts?.count == 2 && operation.strokes == nil)
        store.undoSelectionPart()
        #expect(store.selectionParts.count == 1)
        store.repairTool = "object"; store.selectionSubtract = false
        store.repairPoint = [0.8, 0.8]; store.commitSelectionPart()
        #expect(store.selectionBox == [0, 0, 1, 1])  // 点选物体范围由引擎识别，外接框取整张
        store.clearRepairSelection()
        #expect(store.selectionParts.isEmpty && store.selectionBox == nil)
    }
}
