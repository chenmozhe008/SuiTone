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
}
