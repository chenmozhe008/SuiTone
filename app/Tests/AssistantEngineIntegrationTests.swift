import XCTest
@testable import PhotoEdit

final class AssistantEngineIntegrationTests: XCTestCase {
    @MainActor func testAIUsesRealEngineForQualityReferenceAndRepair() async throws {
        guard ProcessInfo.processInfo.environment["PHOTO_EDIT_RUN_MODEL_TESTS"] == "1" else {
            throw XCTSkip("真实模型测试由阶段验收显式启用")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lake = root.appendingPathComponent("tmp/ui-review-input/IMG_8457.HEIC")
        let small = root.appendingPathComponent("tmp/quality-model-input.png")
        guard FileManager.default.fileExists(atPath: lake.path), FileManager.default.fileExists(atPath: small.path) else {
            throw XCTSkip("缺少公开样本或案例副本")
        }
        let store = WorkspaceStore(engine: EngineClient(root: root))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [lake.path, small.path]])
        let lakeImage = try XCTUnwrap(imported.photos.first(where: { $0.name == lake.lastPathComponent }))
        let smallImage = try XCTUnwrap(imported.photos.first(where: { $0.name == small.lastPathComponent }))
        var lakePhoto = PhotoRecord(imported: lakeImage, assetID: lakeImage.id); lakePhoto.ready = true
        store.photos = [lakePhoto]; store.currentID = lakePhoto.id

        let matchItems = store.photos
        let matchJob = AssistantJob(state: "done", reply: "准备匹配", selection: "none", changes: [
            AssistantChange(id: lakePhoto.assetID, params: lakePhoto.parameters, notes: [],
                            operations: [AssistantOperation(kind: "match", value: 0)])], error: nil)
        await store.applyAssistantResult(matchJob, items: matchItems, referenceIDs: [lakeImage.id])
        store.previewTask?.cancel()
        XCTAssertFalse(store.photos[0].parameters.regions.isEmpty, "参考匹配应学习到共同区域")
        XCTAssertEqual(store.undoChanges.count, 1)
        store.undo(); store.previewTask?.cancel()
        XCTAssertTrue(store.photos[0].parameters.regions.isEmpty)

        let repairItems = store.photos
        let removal = RemovalOperation(box: [0.88, 0.30, 0.998, 0.996], classes: ["railing", "fence"], keep: nil)
        store.selectionBox = removal.box
        let repairJob = AssistantJob(state: "done", reply: "准备修复", selection: "none", changes: [
            AssistantChange(id: lakePhoto.assetID, params: repairItems[0].parameters, notes: [],
                            operations: [AssistantOperation(kind: "repair", value: 0)])], error: nil)
        await store.applyAssistantResult(repairJob, items: repairItems,
                                         repair: (id: lakePhoto.assetID, operation: removal))
        store.previewTask?.cancel()
        XCTAssertNotEqual(store.photos[0].assetID, lakePhoto.assetID)
        XCTAssertEqual(store.photos[0].operations.count, 1)
        XCTAssertNil(store.selectionBox)
        store.undo(); store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].assetID, lakePhoto.assetID)
        XCTAssertTrue(store.photos[0].operations.isEmpty)

        var smallPhoto = PhotoRecord(imported: smallImage, assetID: smallImage.id); smallPhoto.ready = true
        store.photos = [smallPhoto]; store.currentID = smallPhoto.id
        store.undoChanges = []; store.redoChanges = []
        let qualityItems = store.photos
        let qualityJob = AssistantJob(state: "done", reply: "准备增强", selection: "none", changes: [
            AssistantChange(id: smallPhoto.assetID, params: smallPhoto.parameters, notes: [], operations: [
                AssistantOperation(kind: "denoise", value: 1), AssistantOperation(kind: "upscale", value: 2)])], error: nil)
        await store.applyAssistantResult(qualityJob, items: qualityItems)
        store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].quality, QualitySettings(denoise: true, scale: 2))
        XCTAssertEqual(store.undoChanges.count, 1, "一句话的多个操作应是一条事务")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.photos[0].previewPath ?? ""))
        store.undo(); store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].quality, QualitySettings())
    }
}
