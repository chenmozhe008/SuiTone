import XCTest
@testable import PhotoEdit

final class RepairWorkflowTests: XCTestCase {
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

    @MainActor func testCancelLeavesPhotoAndHistoryUntouched() async {
        let store = fixture(), before = store.current!.snapshot
        XCTAssertTrue(store.controlsBlocked)
        store.cancelRepairPreview()
        XCTAssertEqual(store.current!.snapshot, before)
        XCTAssertTrue(store.undoChanges.isEmpty)
        XCTAssertNil(store.repairDraft)
        XCTAssertNil(store.selectionBox)
        XCTAssertFalse(store.controlsBlocked)
    }

    @MainActor func testApplyCreatesOneUndoableChangeAndKeepsColorParameters() async {
        let store = fixture(), before = store.current!.snapshot
        store.applyRepairPreview()
        XCTAssertEqual(store.current!.assetID, "repaired")
        XCTAssertEqual(store.current!.operations.count, 1)
        XCTAssertEqual(store.current!.parameters, before.parameters)
        XCTAssertEqual(store.current!.previewPath, "/after.png")
        XCTAssertEqual(store.undoChanges.count, 1)
        XCTAssertNil(store.repairDraft)
        store.undo()
        store.previewTask?.cancel()
        XCTAssertEqual(store.current!.snapshot.assetID, before.assetID)
        XCTAssertEqual(store.current!.operations, before.operations)
        store.redo()
        store.previewTask?.cancel()
        XCTAssertEqual(store.current!.assetID, "repaired")
        XCTAssertEqual(store.current!.operations.count, 1)
    }

    @MainActor func testStalePreviewCannotReplaceNewerPhotoEdits() async {
        let store = fixture()
        store.photos[0].parameters.exposure = 0.7
        store.applyRepairPreview()
        XCTAssertEqual(store.current!.assetID, "original")
        XCTAssertEqual(store.current!.parameters.exposure, 0.7)
        XCTAssertTrue(store.undoChanges.isEmpty)
        XCTAssertNil(store.repairDraft)
    }

    @MainActor func testInvalidAndTinySelectionsCannotStartRepair() async {
        let store = fixture()
        for box in [[0.1], [0.2, 0.3, 0.2, 0.6], [-0.1, 0.2, 0.4, 0.6], [0.2, 0.3, Double.nan, 0.6]] {
            store.selectionBox = box
            XCTAssertFalse(store.validRepairSelection)
        }
        store.selectionBox = [0.1, 0.2, 0.4, 0.6]
        XCTAssertTrue(store.validRepairSelection)
    }
}
