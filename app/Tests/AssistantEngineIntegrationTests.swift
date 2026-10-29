import Foundation
import Testing
@testable import PhotoEdit

@MainActor @Suite struct AssistantEngineIntegrationTests {
    @Test @MainActor func testClaudeChatRunsThroughLocalServiceAndUpdatesPreview() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/stage2-20261028/city-public.jpg")
        guard FileManager.default.fileExists(atPath: sample.path) else { /* 跳过：缺少公开城市样片 */ return }
        let fixture = root.appendingPathComponent("tmp/claude-chat-fixture-\(UUID().uuidString)")
        let engineDir = fixture.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let pythonPath = String(data: try encoder.encode(root.appendingPathComponent("engine").path), encoding: .utf8)!
        let script = """
        import json, os, sys
        sys.path.insert(0, \(pythonPath))
        import assistant, service
        assistant.executable=lambda provider: '/fake/claude'
        def fake(self, provider, prompt, cancel, *images):
            assert provider == 'claude'
            context=json.loads(prompt.rsplit('\\n',1)[1])
            return {'reply':'已准备胶片风格','selection':'none','actions':[{'id':context['targets'][0]['id'],
                'preset':'film','adjustments':[],'operations':[]}]}
        assistant.AssistantBridge._invoke=fake
        service.serve(sys.argv[sys.argv.index('--root')+1],os.environ['PHOTO_EDIT_SESSION_TOKEN'])
        """
        try script.write(to: engineDir.appendingPathComponent("service.py"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(engine: EngineClient(root: fixture))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [sample.path]])
        let image = try #require(imported.photos.first)
        var photo = PhotoRecord(imported: image, assetID: image.id); photo.ready = true
        store.photos = [photo]; store.currentID = photo.id
        let before: PreviewResponse = try await store.engine.request("preview", body: ["id": image.id,
            "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
        store.providers = [AssistantProvider(id: "claude", title: "Claude Code", available: true)]
        store.visionConsents.insert("claude")
        store.assistantProvider = "claude"; store.chatDraft = "调成明显的胶片风格"
        store.sendChat()
        let task = try #require(store.assistantTask)
        await task.value
        #expect(!(store.chatting))
        #expect(store.undoChanges.count == 1, Comment(rawValue: store.chatMessages.map(\.text).joined(separator: " | ")))
        #expect(store.chatMessages.last?.text.contains("已完成调整") == true, Comment(rawValue: store.chatMessages.map(\.text).joined(separator: " | ")))
        let previewTask = store.previewTask
        await previewTask?.value
        let afterPath = try #require(store.photos[0].previewPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: before.preview)) != Data(contentsOf: URL(fileURLWithPath: afterPath)))
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters == photo.parameters)
    }

    @Test @MainActor func testRecordedClaudeVisionAdjustmentChangesPreviewAndCanBeUndone() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/stage2-20261028/city-public.jpg")
        let recorded = root.appendingPathComponent("output/stage2-20261028/claude-edit-check-20261029.json")
        guard FileManager.default.fileExists(atPath: sample.path), FileManager.default.fileExists(atPath: recorded.path) else {
            /* 跳过：缺少公开样片或已保存的 Claude 响应 */ return
        }
        let store = WorkspaceStore(engine: EngineClient(root: root))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [sample.path]])
        let image = try #require(imported.photos.first)
        var photo = PhotoRecord(imported: image, assetID: image.id); photo.ready = true
        store.photos = [photo]; store.currentID = photo.id
        let before: PreviewResponse = try await store.engine.request("preview", body: ["id": image.id,
            "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recorded)) as? [String: Any])
        var result = try #require(json["result"] as? [String: Any])
        var changes = try #require(result["changes"] as? [[String: Any]])
        #expect(changes.count == 1)
        changes[0]["id"] = image.id; result["changes"] = changes
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(AssistantJob.self, from: JSONSerialization.data(withJSONObject: result))
        await store.applyAssistantResult(job, items: store.photos); store.previewTask?.cancel()
        #expect(store.undoChanges.count == 1)
        #expect(store.photos[0].parameters != photo.parameters)
        let after: PreviewResponse = try await store.engine.request("preview", body: ["id": image.id,
            "params": try EngineClient.object(store.photos[0].parameters), "quality": try EngineClient.object(photo.quality)])
        #expect(try Data(contentsOf: URL(fileURLWithPath: before.preview)) != Data(contentsOf: URL(fileURLWithPath: after.preview)))
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters == photo.parameters)
    }

    @Test @MainActor func testAIUsesRealEngineForQualityReferenceAndRepair() async throws {
        guard ProcessInfo.processInfo.environment["PHOTO_EDIT_RUN_MODEL_TESTS"] == "1" else {
            /* 跳过：真实模型测试由阶段验收显式启用 */ return
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lake = root.appendingPathComponent("tmp/ui-review-input/IMG_8457.HEIC")
        let small = root.appendingPathComponent("tmp/quality-model-input.png")
        guard FileManager.default.fileExists(atPath: lake.path), FileManager.default.fileExists(atPath: small.path) else {
            /* 跳过：缺少公开样本或案例副本 */ return
        }
        let store = WorkspaceStore(engine: EngineClient(root: root))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [lake.path, small.path]])
        let lakeImage = try #require(imported.photos.first(where: { $0.name == lake.lastPathComponent }))
        let smallImage = try #require(imported.photos.first(where: { $0.name == small.lastPathComponent }))
        var lakePhoto = PhotoRecord(imported: lakeImage, assetID: lakeImage.id); lakePhoto.ready = true
        store.photos = [lakePhoto]; store.currentID = lakePhoto.id

        let matchItems = store.photos
        let matchJob = AssistantJob(state: "done", reply: "准备匹配", selection: "none", changes: [
            AssistantChange(id: lakePhoto.assetID, params: lakePhoto.parameters, notes: [],
                            operations: [AssistantOperation(kind: "match", value: 0)])], error: nil)
        await store.applyAssistantResult(matchJob, items: matchItems, referenceIDs: [lakeImage.id])
        store.previewTask?.cancel()
        #expect(!(store.photos[0].parameters.regions.isEmpty), Comment(rawValue: "参考匹配应学习到共同区域"))
        #expect(store.undoChanges.count == 1)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions.isEmpty)

        let repairItems = store.photos
        let removal = RemovalOperation(box: [0.88, 0.30, 0.998, 0.996], classes: ["railing", "fence"], keep: nil)
        store.selectionBox = removal.box
        let repairJob = AssistantJob(state: "done", reply: "准备修复", selection: "none", changes: [
            AssistantChange(id: lakePhoto.assetID, params: repairItems[0].parameters, notes: [],
                            operations: [AssistantOperation(kind: "repair", value: 0)])], error: nil)
        await store.applyAssistantResult(repairJob, items: repairItems,
                                         repair: (id: lakePhoto.assetID, operation: removal))
        store.previewTask?.cancel()
        #expect(store.photos[0].assetID != lakePhoto.assetID)
        #expect(store.photos[0].operations.count == 1)
        #expect(store.selectionBox == nil)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].assetID == lakePhoto.assetID)
        #expect(store.photos[0].operations.isEmpty)

        var smallPhoto = PhotoRecord(imported: smallImage, assetID: smallImage.id); smallPhoto.ready = true
        store.photos = [smallPhoto]; store.currentID = smallPhoto.id
        store.undoChanges = []; store.redoChanges = []
        let qualityItems = store.photos
        let qualityJob = AssistantJob(state: "done", reply: "准备增强", selection: "none", changes: [
            AssistantChange(id: smallPhoto.assetID, params: smallPhoto.parameters, notes: [], operations: [
                AssistantOperation(kind: "denoise", value: 1), AssistantOperation(kind: "upscale", value: 2)])], error: nil)
        await store.applyAssistantResult(qualityJob, items: qualityItems)
        store.previewTask?.cancel()
        #expect(store.photos[0].quality == QualitySettings(denoise: true, scale: 2))
        #expect(store.undoChanges.count == 1, Comment(rawValue: "一句话的多个操作应是一条事务"))
        #expect(FileManager.default.fileExists(atPath: store.photos[0].previewPath ?? ""))
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].quality == QualitySettings())
    }
}
