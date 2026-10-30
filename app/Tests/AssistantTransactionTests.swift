import Foundation
import Testing
@testable import PhotoEdit

@MainActor @Suite struct AssistantTransactionTests {
    @Test @MainActor func testVariantSwitchingAndStaleProtection() {
        let store = fixture(), source = store.photos[0], group = UUID()
        var warm = source.parameters, cool = source.parameters
        warm.temperature = 0.3; cool.temperature = -0.3
        let first = VariantPreview(group: group, photoID: source.id, baseline: source.snapshot,
                                   title: "暖调", params: warm, notes: [], preview: "/warm.png")
        let second = VariantPreview(group: group, photoID: source.id, baseline: source.snapshot,
                                    title: "冷调", params: cool, notes: [], preview: "/cool.png")
        store.applyVariant(first)
        #expect(store.current?.parameters.temperature == 0.3)
        store.applyVariant(second)
        #expect(store.current?.parameters.temperature == -0.3)
        store.undo(); store.previewTask?.cancel()
        #expect(store.current?.parameters.temperature == 0.3)
        store.applyVariant(second)
        #expect(store.current?.parameters.temperature == -0.3)
        store.undo(); store.previewTask?.cancel()
        store.change("手动调整") { $0.exposure = 0.5 }
        store.applyVariant(second)
        #expect(store.current?.parameters.exposure == 0.5)
        #expect(store.current?.parameters.temperature == 0.3)
        #expect(store.status.contains("重新生成"))
        store.previewTask?.cancel()
    }

    @Test @MainActor func testReviewCannotAlterTheUserSelectionGeometry() async {
        let store = fixture(), items = store.photos, key = "selection-123456789abc"
        var first = items[0].parameters
        first.manualMasks[key] = RemovalOperation(box: [0.1, 0.1, 0.4, 0.4])
        var local = LocalAdjustment(); local.exposure = 0.2; first.local[key] = local
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var changed = prepared[0].parameters; changed.manualMasks[key]?.box = [0.5, 0.5, 0.9, 0.9]
            return [AssistantChange(id: "original", params: changed, notes: [])]
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.manualMasks[key]?.box == [0.1, 0.1, 0.4, 0.4])
        #expect(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }
    @Test @MainActor func testReceiptUndoOnlyUndoesItsOwnLatestChange() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.2
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: params, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items)
        let id = store.chatMessages.last!.changeID!
        store.change("手动色温") { $0.temperature = 0.3 }
        store.undoAssistantChange(id)
        #expect(store.photos[0].parameters.exposure == 0.2)
        #expect(store.photos[0].parameters.temperature == 0.3)
        store.undo(); store.previewTask?.cancel()
        store.undoAssistantChange(id); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.chatMessages.last!.wasUndone)
    }
    @Test @MainActor func testReviewSelectionFollowsRepairedAsset() {
        let store = fixture(), originals = store.photos
        var edited = originals[0]; edited.assetID = "repaired"
        let operation = RemovalOperation(box: [0.1, 0.2, 0.4, 0.5])
        let selected = store.reviewSelection(photos: [edited], originals: originals, repair: ("original", operation))
        #expect(selected?.id == "repaired")
        #expect(selected?.operation.box == operation.box)
        #expect(store.reviewSelection(photos: [edited], originals: originals, repair: ("other", operation)) == nil)
    }
    @Test @MainActor func testReviewFeedbackRemainsVisibleAfterSuccessfulAdjustment() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.2
        let job = AssistantJob(state: "done", reply: "建议提亮", selection: "none", changes: [
            AssistantChange(id: "original", params: params, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { _ in [] },
            reviewFeedback: { "人物仍偏暗，变化不够明显。" })
        store.previewTask?.cancel()
        #expect(store.chatMessages.last!.text.contains("人物仍偏暗，变化不够明显"))
        #expect(store.photos[0].parameters.exposure == 0.2)
    }

    @Test @MainActor func testReviewFailureIsVisibleWithoutExpandingDetails() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.2
        let job = AssistantJob(state: "done", reply: "建议提亮", selection: "none", changes: [
            AssistantChange(id: "original", params: params, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { _ in
            throw EngineError(message: "额度不足")
        })
        store.previewTask?.cancel()
        #expect(store.chatMessages.last!.text.contains("复看未完成，保留首轮调整：额度不足"))
        #expect(store.photos[0].parameters.exposure == 0.2)
    }

    @Test @MainActor func testVisualReviewCannotAddDifferentRegion() async {
        let store = fixture(), items = store.photos
        let region = RegionAdjustment(mean: [60, 1, 2], sourceMean: [50, 1, 2], chromaScale: [1, 1],
            lumaX: [0, 100], lumaY: [0, 100], referenceLumaMean: 50, strength: 1, referenceCount: 0)
        var first = items[0].parameters; first.regions["person"] = region
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.regions["sky"] = region
            return [AssistantChange(id: "original", params: altered, notes: ["天空"])]
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions["person"] != nil)
        #expect(store.photos[0].parameters.regions["sky"] == nil)
        #expect(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions.isEmpty)
    }

    @Test @MainActor func testVisualReviewCannotAlterUnrequestedRegionChannel() async {
        let store = fixture()
        let region = RegionAdjustment(mean: [50, 1, 2], sourceMean: [50, 1, 2], chromaScale: [1, 1],
            lumaX: [0, 100], lumaY: [0, 100], referenceLumaMean: 50, strength: 1, referenceCount: 0)
        store.photos[0].parameters.regions["person"] = region
        let items = store.photos
        var first = items[0].parameters; first.regions["person"]!.mean[0] = 60
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.regions["person"]!.mean[1] = 12
            return [AssistantChange(id: "original", params: altered, notes: ["人物色彩"])]
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions["person"]?.mean == [60, 1, 2])
        #expect(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }

    @Test @MainActor func testNewPersonRegionReviewCannotAlterUnrequestedColor() async {
        let store = fixture(), items = store.photos
        let region = RegionAdjustment(mean: [60, 1, 2], sourceMean: [50, 1, 2], chromaScale: [1, 1],
            lumaX: [0, 100], lumaY: [0, 100], referenceLumaMean: 50, strength: 1, referenceCount: 0)
        var first = items[0].parameters; first.regions["person"] = region
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.regions["person"]!.mean[1] = 12
            return [AssistantChange(id: "original", params: altered, notes: ["人物色彩"])]
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions["person"]?.mean == [60, 1, 2])
        #expect(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }

    @Test @MainActor func testNewPersonRegionCanRefineRequestedBrightness() async {
        let store = fixture(), items = store.photos
        let region = RegionAdjustment(mean: [60, 1, 2], sourceMean: [50, 1, 2], chromaScale: [1, 1],
            lumaX: [0, 100], lumaY: [0, 100], referenceLumaMean: 50, strength: 1, referenceCount: 0)
        var first = items[0].parameters; first.regions["person"] = region
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.regions["person"]!.mean[0] = 65
            return [AssistantChange(id: "original", params: altered, notes: ["人物亮度"])]
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions["person"]?.mean == [65, 1, 2])
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.regions.isEmpty)
    }

    @Test @MainActor func testCancellingSuggestionBeforeJobIDStillCancelsServerJob() async throws {
        let store = WorkspaceStore()
        var cancelledID: String?
        let task = Task {
            try await store.startRecommendationJob(start: {
                try await Task.sleep(for: .milliseconds(80))
                return "delayed-job"
            }, cancel: { id in cancelledID = id })
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        let result = try await task.value
        #expect(result == nil)
        #expect(cancelledID == "delayed-job")
    }

    @Test @MainActor func testVisualReviewPreservesExplicitNumericRequest() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.2
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.exposure = 0.3
            return [AssistantChange(id: "original", params: altered, notes: [])]
        }, preserveExactValues: true)
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0.2)
        #expect(store.chatMessages.last!.notes.contains { $0.contains("指定的数值") })
    }

    @Test @MainActor func testVisualReviewCannotAddAnUnrequestedParameter() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.temperature = 0.4
            return [AssistantChange(id: "original", params: altered, notes: ["色温"])]
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0.3)
        #expect(store.photos[0].parameters.temperature == 0)
        #expect(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }

    @Test @MainActor func testVisualReviewIsOneTransactionAndUndoRestoresOriginal() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: ["首轮曝光"])], error: nil)
        var reviews = 0
        await store.applyAssistantResult(job, items: items, review: { prepared in
            reviews += 1
            #expect(prepared[0].parameters.exposure == 0.3)
            var refined = prepared[0].parameters; refined.exposure = 0.35
            return [AssistantChange(id: "original", params: refined, notes: ["复看曝光"])]
        })
        store.previewTask?.cancel()
        #expect(reviews == 1)
        #expect(store.photos[0].parameters.exposure == 0.35)
        #expect(store.undoChanges.count == 1)
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0)
    }

    @Test @MainActor func testVisualReviewCannotOverwriteChangesMadeWhileWaiting() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            store.photos[0].quality.denoise = true
            return []
        })
        store.previewTask?.cancel()
        #expect(store.photos[0].quality.denoise)
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.undoChanges.isEmpty)
        #expect(store.chatMessages.last!.notes.contains { $0.contains("已跳过") })
    }

    @Test @MainActor func testVisionConsentIsRememberedPerProvider() {
        let store = WorkspaceStore()
        let saved = store.visionConsents
        store.visionConsents = []
        store.assistantProvider = "codex"
        #expect(!(store.visionEnabled))
        store.visionConsents.insert("codex")
        #expect(store.visionEnabled)
        store.assistantProvider = "claude"
        #expect(!(store.visionEnabled))
        #expect(WorkspaceStore().visionConsents == ["codex"])
        store.visionConsents = saved
        store.assistantProvider = "codex"
    }

    @Test @MainActor func testAPIProviderNeedsKeyModelAndCustomAddress() {
        let store = WorkspaceStore()
        store.providers = [AssistantProvider(id: "codex", title: "Codex", available: true),
                           AssistantProvider(id: "qwen", title: "通义千问", available: true, kind: "api", models: ["qwen3-vl-plus"]),
                           AssistantProvider(id: "custom", title: "自定义", available: true, kind: "api", needsBaseUrl: true)]
        store.assistantProvider = "codex"
        #expect(store.assistantReady)
        #expect(store.apiCredentials == nil)
        store.assistantProvider = "qwen"
        store.apiKeys["qwen"] = ""
        #expect(!store.assistantReady)
        store.apiKeys["qwen"] = "fixture"
        #expect(store.assistantReady)
        #expect(store.apiCredentials?.model == store.apiModels["qwen"] ?? "qwen3-vl-plus")
        var body: [String: Any] = [:]
        store.apiCredentials?.apply(to: &body)
        #expect(body["api_key"] as? String == "fixture")
        #expect(body["base_url"] == nil)
        store.assistantProvider = "custom"
        store.apiKeys["custom"] = "fixture"
        store.apiModels["custom"] = "local-vl"
        let saved = store.customBaseURL
        store.customBaseURL = ""
        #expect(!store.assistantReady)
        store.customBaseURL = "http://localhost:11434/v1"
        #expect(store.assistantReady)
        store.customBaseURL = saved
        store.assistantProvider = "codex"
    }

    @Test @MainActor func testTargetsFollowMultiSelectionAndDefaultToCurrent() {
        let store = WorkspaceStore()
        let photos = ["a", "b", "c"].map { id in
            PhotoRecord(imported: ImportedPhoto(id: id, path: "/\(id).jpg", name: id, thumbnail: "/t", original: "/o",
                                                width: 10, height: 10, similarTo: nil), assetID: id)
        }
        store.photos = photos; store.currentID = "a"; store.selectedIDs = ["a"]
        #expect(store.targets.map(\.id) == ["a"])
        store.selectedIDs = ["a", "c"]
        #expect(store.targets.map(\.id) == ["a", "c"])
        #expect(store.scopeLabel == "所选 2 张")
        store.selectedIDs = ["b", "c"]  // 当前照片不在所选里时只改当前
        #expect(store.targets.map(\.id) == ["a"])
    }

    @Test func testLocalAdjustmentsEncodeForEngine() throws {
        var params = AdjustmentParameters()
        params.local["sky"] = LocalAdjustment()
        params.local["sky"]?.exposure = -0.3
        params.texture = 0.4
        let object = try EngineClient.object(params)
        let local = try #require(object["local"] as? [String: Any])
        let sky = try #require(local["sky"] as? [String: Any])
        #expect(sky["exposure"] as? Double == -0.3)
        #expect(sky["feather"] as? Double == 0.5)
        #expect(object["texture"] as? Double == 0.4)
        let decoded = try JSONDecoder().decode(AdjustmentParameters.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.local["sky"]?.exposure == -0.3)
    }

    @Test func testGeneratedVersionIsRecordedAsOperation() throws {
        let generated = RemovalOperation(box: [0, 0, 1, 1], generated: "/gen/abc.png")
        let object = try EngineClient.object(generated)
        #expect(object["generated"] as? String == "/gen/abc.png")
        let removal = try EngineClient.object(RemovalOperation(box: [0.1, 0.1, 0.2, 0.2], strokes: [[[0.1, 0.1]]], radius: 0.02))
        #expect(removal["generated"] == nil)  // 普通移除不带生成字段，旧工程照常复原
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(RemovalOperation.self, from: data) == generated)
    }

    @MainActor private func fixture() -> WorkspaceStore {
        let store = WorkspaceStore()
        let image = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg", thumbnail: "/thumb.png",
                                  original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: image, assetID: "original")]
        store.currentID = "photo"
        return store
    }

    @Test @MainActor func testUndoAIChangeDoesNotUndoQualityChangedDuringRequest() async {
        let store = fixture()
        let requested = store.photos
        store.photos[0].quality.denoise = true
        var params = requested[0].parameters
        params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已调整", selection: "none",
            changes: [AssistantChange(id: "original", params: params, notes: ["曝光 0 → 0.3"])], error: nil)
        await store.applyAssistantResult(job, items: requested)
        store.previewTask?.cancel()
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.photos[0].quality.denoise, Comment(rawValue: "撤销 AI 时不能撤销用户在等待期间更改的画质"))
    }

    @Test @MainActor func testReceiptTracksUndoAndRedo() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已调整", selection: "none",
            changes: [AssistantChange(id: "original", params: params, notes: ["曝光 0 → 0.3"])], error: nil)
        await store.applyAssistantResult(job, items: items); store.previewTask?.cancel()
        #expect(!(store.chatMessages.last!.wasUndone))
        store.undo(); store.previewTask?.cancel()
        #expect(store.chatMessages.last!.wasUndone)
        store.redo(); store.previewTask?.cancel()
        #expect(!(store.chatMessages.last!.wasUndone))
    }

    @Test @MainActor func testCancelBeforeJobIDRejectsLateResult() async {
        let store = fixture(), items = store.photos
        store.chatting = true
        store.cancelChat()
        #expect(store.assistantCancellationRequested)
        var params = items[0].parameters; params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已调整", selection: "none",
            changes: [AssistantChange(id: "original", params: params, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items)
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.undoChanges.isEmpty)
    }

    @Test @MainActor func testAIUndoUsesSameStackAndRefusesStaleTarget() async {
        let store = fixture()
        store.change("曝光") { $0.exposure = 0.4 }; store.previewTask?.cancel()
        let items = store.photos, candidate = store.undoChanges.last!.id
        let job = AssistantJob(state: "done", reply: "准备撤销", selection: "none", changes: [
            AssistantChange(id: "original", params: items[0].parameters, notes: [],
                            operations: [AssistantOperation(kind: "undo", value: 0)])], error: nil)
        await store.applyAssistantResult(job, items: items, undoCandidate: candidate)
        store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.redoChanges.count == 1)
        store.redo(); store.previewTask?.cancel()
        store.change("色温") { $0.temperature = 0.2 }; store.previewTask?.cancel()
        let latest = store.photos[0].snapshot
        await store.applyAssistantResult(job, items: items, undoCandidate: candidate)
        #expect(store.photos[0].snapshot == latest)
        #expect(store.chatMessages.last!.text.contains("没有操作"))
    }

    @Test @MainActor func testAIUndoDoesNotUndoSliderStillBeingDragged() async {
        let store = fixture()
        store.change("曝光") { $0.exposure = 0.4 }; store.previewTask?.cancel()
        let items = store.photos, candidate = store.undoChanges.last!.id
        store.beginEditing("色温")
        store.update { $0.temperature = 0.2 }; store.previewTask?.cancel()
        let job = AssistantJob(state: "done", reply: "准备撤销", selection: "none", changes: [
            AssistantChange(id: "original", params: items[0].parameters, notes: [],
                            operations: [AssistantOperation(kind: "undo", value: 0)])], error: nil)
        await store.applyAssistantResult(job, items: items, undoCandidate: candidate)
        #expect(store.photos[0].parameters.exposure == 0.4)
        #expect(store.photos[0].parameters.temperature == 0.2)
        #expect(store.undoChanges.count == 2)
        #expect(store.chatMessages.last!.text.contains("没有操作"))
    }

    @Test @MainActor func testPreparedOperationCannotOverwriteNewerQuality() async {
        let store = fixture(), source = store.photos[0]
        var params = source.parameters; params.exposure = 0.5
        let prepared = try! await store.prepareOperation(.parameters(params, name: "AI 调整", notes: []), on: source)
        store.photos[0].quality.denoise = true
        #expect(!(store.commitPrepared(prepared, expected: source.snapshot)))
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.photos[0].quality.denoise)
    }

    @Test @MainActor func testFailedMultiStepRequestCannotClaimOrApplySuccess() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已经完成", selection: "none", changes: [
            AssistantChange(id: "original", params: params, notes: ["曝光"],
                            operations: [AssistantOperation(kind: "match", value: 0)])], error: nil)
        await store.applyAssistantResult(job, items: items)
        #expect(store.photos[0].parameters.exposure == 0)
        #expect(store.undoChanges.isEmpty)
        #expect(store.chatMessages.last!.text.contains("没有应用"))
        #expect(!(store.chatMessages.last!.text.contains("已经完成")))
    }

    @Test @MainActor func testNoOperationCannotClaimItChangedPhoto() async {
        let store = fixture(), items = store.photos
        let job = AssistantJob(state: "done", reply: "我已经把天空调蓝了。", selection: "none", changes: [], error: nil)
        await store.applyAssistantResult(job, items: items)
        #expect(store.undoChanges.isEmpty)
        #expect(store.chatMessages.last!.text.contains("没有执行调整"))
        #expect(!(store.chatMessages.last!.text.contains("调蓝了")))
    }

    @Test @MainActor func testBatchSkipsChangedPhotoAndUndoPreservesItsNewEdit() async {
        let store = fixture()
        let imported = ImportedPhoto(id: "second", path: "/second.jpg", name: "second.jpg", thumbnail: "/thumb.png",
                                     original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos.append(PhotoRecord(imported: imported, assetID: "second-asset"))
        let items = store.photos
        store.photos[0].parameters.exposure = 0.7
        var first = items[0].parameters; first.exposure = 0.3
        var second = items[1].parameters; second.exposure = 0.4
        let job = AssistantJob(state: "done", reply: "两张都已完成", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: []),
            AssistantChange(id: "second-asset", params: second, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0.7)
        #expect(store.photos[1].parameters.exposure == 0.4)
        #expect(store.chatMessages.last!.affectedPhotos == ["second.jpg"])
        #expect(store.chatMessages.last!.notes.contains { $0.contains("fixture.jpg") && $0.contains("已跳过") })
        store.undo(); store.previewTask?.cancel()
        #expect(store.photos[0].parameters.exposure == 0.7)
        #expect(store.photos[1].parameters.exposure == 0)
    }
}
