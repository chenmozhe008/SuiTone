import Foundation
import ImageIO
import Testing
@testable import PhotoEdit

@MainActor @Suite struct AssistantEngineIntegrationTests {
    @Test @MainActor func testImportKeepsOriginalWithoutAutomaticAdjustment() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("tmp/import-original-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGO0qdjCgA0wYRUdtBIAHQ8BeIKmlrAAAAAASUVORK5CYII="))
        try image.write(to: fixture)
        let store = WorkspaceStore(engine: EngineClient(root: root))
        store.importURLs([fixture]); await store.importTask?.value
        let photo = try #require(store.current)
        #expect(photo.parameters == AdjustmentParameters())
        #expect(photo.lookName == "原图" && photo.operations.isEmpty && photo.ready)
        #expect(store.undoChanges.isEmpty)
    }
    @Test @MainActor func testSuggestionUsesSelectionAndSkipsUnavailableRegions() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("tmp/suggestion-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let engineDir = fixture.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let pythonPath = String(data: try encoder.encode(root.appendingPathComponent("engine").path), encoding: .utf8)!
        let script = """
        import os,sys
        sys.path.insert(0, \(pythonPath))
        import service
        def fake(self,key,card_id,raw,quality=None):
            asset=self.asset(key)
            if card_id=='sky' and asset.path.stem=='second':
                raise ValueError('这张照片没有可用的此项建议')
            p=service.parameters(raw); p['shadows']=0.12
            return dict(params=p,title='测试建议',notes=['阴影 0.00 → 0.12'],preview=str(asset.image_path))
        service.Engine.apply_suggestion=fake
        service.serve(sys.argv[sys.argv.index('--root')+1],os.environ['PHOTO_EDIT_SESSION_TOKEN'])
        """
        try script.write(to: engineDir.appendingPathComponent("service.py"), atomically: true, encoding: .utf8)
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGO0qdjCgA0wYRUdtBIAHQ8BeIKmlrAAAAAASUVORK5CYII="))
        let paths = ["first", "second", "third"].map { fixture.appendingPathComponent($0 + ".png") }
        for path in paths { try image.write(to: path) }
        let store = WorkspaceStore(engine: EngineClient(root: fixture))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": paths.map(\.path)])
        #expect(imported.photos.count == 3)
        store.photos = imported.photos.map { item in var photo = PhotoRecord(imported: item, assetID: item.id); photo.ready = true; return photo }
        store.currentID = store.photos[0].id
        store.selectedIDs = Set(store.photos.prefix(2).map(\.id))
        store.applySuggestion(SuggestionCard(id: "shadows", title: "提亮暗部"))
        await store.batchTask?.value
        #expect(store.photos[0].parameters.shadows == 0.12 && store.photos[1].parameters.shadows == 0.12)
        #expect(store.photos[2].parameters.shadows == 0)
        #expect(store.chatMessages.last?.text == "已应用：提亮暗部")
        #expect(store.chatMessages.last?.notes.count == 2)
        #expect(store.chatMessages.last?.affectedPhotos.count == 2)
        let changeID = try #require(store.chatMessages.last?.changeID)
        store.undoAssistantChange(changeID)
        #expect(store.chatMessages.last?.wasUndone == true)
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.shadows == 0 && store.photos[1].parameters.shadows == 0)
        store.redo(); store.previewTask?.cancel()
        #expect(store.chatMessages.last?.wasUndone == false)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.shadows == 0 && store.photos[1].parameters.shadows == 0)
        store.applySuggestion(SuggestionCard(id: "sky", title: "天空更通透"))
        await store.batchTask?.value
        #expect(store.photos[0].parameters.shadows == 0.12 && store.photos[1].parameters.shadows == 0)
        #expect(store.status.contains("1 张不适用，跳过"))
        #expect(store.undoChanges.count == 1)
        store.previewTask?.cancel()
    }

    @Test @MainActor func testMultipleVariantsRenderThroughEngineAndApplyOnSelection() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/stage2-20261028/city-public.jpg")
        guard FileManager.default.fileExists(atPath: sample.path) else { return }
        let fixture = root.appendingPathComponent("tmp/variants-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
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
            context=json.loads(prompt.rsplit('\\n',1)[1]); key=context['targets'][0]['id']
            assert images and images[0]
            variants=[{'id':key,'title':name,'preset':'keep','operations':[],
                       'adjustments':[{'parameter':'temperature','mode':'add','value':value}]}
                      for name,value in [('暖调',.3),('冷调',-.3),('自然',0.)]]
            return {'reply':'三个方向供比较','selection':'none','actions':[],'variants':variants}
        assistant.AssistantBridge._invoke=fake
        service.serve(sys.argv[sys.argv.index('--root')+1],os.environ['PHOTO_EDIT_SESSION_TOKEN'])
        """
        try script.write(to: engineDir.appendingPathComponent("service.py"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(engine: EngineClient(root: fixture))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [sample.path]])
        let image = try #require(imported.photos.first)
        var photo = PhotoRecord(imported: image, assetID: image.id); photo.ready = true
        store.photos = [photo]; store.currentID = photo.id
        store.providers = [AssistantProvider(id: "claude", title: "Claude Code", available: true)]
        store.visionConsents.insert("claude"); store.assistantProvider = "claude"
        store.chatDraft = "给我三个不同的效果并展示"
        store.sendChat()
        let task = try #require(store.assistantTask); await task.value
        let previews = try #require(store.chatMessages.last?.variants)
        #expect(previews.count == 3)
        #expect(store.current?.parameters.temperature == photo.parameters.temperature)
        #expect(previews.allSatisfy { FileManager.default.fileExists(atPath: $0.preview) })
        store.applyVariant(previews[0])
        #expect(store.current?.parameters.temperature == 0.3)
        store.applyVariant(previews[1])
        #expect(store.current?.parameters.temperature == -0.3)
        store.undo(); store.previewTask?.cancel()
        #expect(store.current?.parameters.temperature == 0.3)
    }

    @Test @MainActor func testClaudeChatRunsThroughLocalServiceAndUpdatesPreview() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/stage2-20261028/city-public.jpg")
        guard FileManager.default.fileExists(atPath: sample.path) else { /* 跳过：缺少公开城市样片 */ return }
        let fixture = root.appendingPathComponent("tmp/claude-chat-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
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

    @Test @MainActor func testGenerationProposalNeedsConfirmationThenBecomesUndoableVersion() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/stage2-20261028/city-public.jpg")
        guard FileManager.default.fileExists(atPath: sample.path) else { /* 跳过：缺少公开城市样片 */ return }
        let fixture = root.appendingPathComponent("tmp/generation-fixture-\(UUID().uuidString)")
        let engineDir = fixture.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let pythonPath = String(data: try encoder.encode(root.appendingPathComponent("engine").path), encoding: .utf8)!
        let generatedPath = String(data: try encoder.encode(fixture.appendingPathComponent("generated").path), encoding: .utf8)!
        let script = """
        import json, os, sys
        from pathlib import Path
        sys.path.insert(0, \(pythonPath))
        import assistant, service
        assistant.executable=lambda provider: '/fake/claude'
        def fake(self, provider, prompt, cancel, *images):
            return {'reply':'换背景需要生成新图','selection':'none','actions':[],'variants':[],
                    'generate':{'needed':True,'prompt':'把背景换成雪山，人物不变'}}
        assistant.AssistantBridge._invoke=fake
        original=service.Engine.__init__
        def init(self, root):
            original(self, root); self.generated_dir=Path(\(generatedPath))
        service.Engine.__init__=init
        service.serve(sys.argv[sys.argv.index('--root')+1],os.environ['PHOTO_EDIT_SESSION_TOKEN'])
        """
        try script.write(to: engineDir.appendingPathComponent("service.py"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(engine: EngineClient(root: fixture))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [sample.path]])
        let image = try #require(imported.photos.first)
        var photo = PhotoRecord(imported: image, assetID: image.id); photo.ready = true
        store.photos = [photo]; store.currentID = photo.id; store.selectedIDs = [photo.id]
        store.providers = [AssistantProvider(id: "claude", title: "Claude Code", available: true)]
        store.assistantProvider = "claude"; store.visionConsents.insert("claude")
        store.imageServices = [ImageService(id: "mock", title: "模拟出图（测试用）", defaultModel: "mock", paid: false)]
        store.imageService = "mock"
        store.chatDraft = "把背景换成雪山"
        store.sendChat()
        await store.assistantTask?.value
        let message = try #require(store.chatMessages.last)
        let card = try #require(message.generation)
        #expect(card.state == "proposed" && card.prompt.contains("雪山"))
        #expect(store.photos[0].assetID == image.id)  // 确认前不发送、不改照片
        store.startGeneration(message.id)
        await store.generationTask?.value
        let done = try #require(store.chatMessages.last?.generation)
        #expect(done.state == "done", Comment(rawValue: done.error ?? ""))
        #expect(store.photos[0].assetID != image.id)
        #expect(store.photos[0].operations.last?.generated?.contains("generation-fixture") == true)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].assetID == image.id && store.photos[0].operations.isEmpty)
    }

    @Test @MainActor func testAIEditPanelOnlySelectionBecomesVersion() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = root.appendingPathComponent("output/stage2-20261028/city-public.jpg")
        guard FileManager.default.fileExists(atPath: sample.path) else { /* 跳过：缺少公开城市样片 */ return }
        let fixture = root.appendingPathComponent("tmp/aiedit-fixture-\(UUID().uuidString)")
        let engineDir = fixture.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let pythonPath = String(data: try encoder.encode(root.appendingPathComponent("engine").path), encoding: .utf8)!
        let generatedPath = String(data: try encoder.encode(fixture.appendingPathComponent("generated").path), encoding: .utf8)!
        let script = """
        import os, sys
        from pathlib import Path
        sys.path.insert(0, \(pythonPath))
        import service
        original=service.Engine.__init__
        def init(self, root):
            original(self, root); self.generated_dir=Path(\(generatedPath))
        service.Engine.__init__=init
        service.serve(sys.argv[sys.argv.index('--root')+1],os.environ['PHOTO_EDIT_SESSION_TOKEN'])
        """
        try script.write(to: engineDir.appendingPathComponent("service.py"), atomically: true, encoding: .utf8)
        let store = WorkspaceStore(engine: EngineClient(root: fixture))
        let imported: ImportResponse = try await store.engine.request("import", body: ["paths": [sample.path]])
        let image = try #require(imported.photos.first)
        var photo = PhotoRecord(imported: image, assetID: image.id); photo.ready = true
        store.photos = [photo]; store.currentID = photo.id; store.selectedIDs = [photo.id]
        store.imageServices = [ImageService(id: "mock", title: "模拟出图（测试用）", defaultModel: "mock", paid: false)]
        store.imageService = "mock"
        store.inspectorTab = "aiedit"
        store.selectionParts = [SelectionPart(box: [0.5, 0, 1, 1])]; store.refreshSelection()
        store.startAIEdit(prompt: "把右半边换掉", onlySelection: true)
        await store.generationTask?.value
        let card = try #require(store.chatMessages.last?.generation)
        #expect(card.state == "done", Comment(rawValue: card.error ?? ""))
        #expect(card.selection?.parts?.count == 1)
        #expect(store.photos[0].operations.last?.generated != nil)
        #expect(store.photoVersions.count == 2)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].operations.isEmpty && store.photoVersions.count == 1)
        store.photos[0].parameters.crop = [0.1, 0.1, 0.7, 0.7]
        store.startAIEdit(prompt: "换背景", onlySelection: false, aspectRatio: "16:9")
        await store.generationTask?.value
        let resized = try #require(store.chatMessages.last?.generation)
        #expect(resized.state == "done", Comment(rawValue: resized.error ?? ""))
        #expect(resized.aspectRatio == "16:9" && store.photos[0].parameters.crop == nil)
        let path = try #require(store.photos[0].operations.last?.generated)
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let output = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(abs(Double(output.width) / Double(output.height) - 16.0 / 9.0) < 0.01)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.crop == [0.1, 0.1, 0.7, 0.7])
    }
}
