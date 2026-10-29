import XCTest
@testable import PhotoEdit

final class AssistantTransactionTests: XCTestCase {
    @MainActor func testVisualReviewCannotAddDifferentRegion() async {
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
        XCTAssertNotNil(store.photos[0].parameters.regions["person"])
        XCTAssertNil(store.photos[0].parameters.regions["sky"])
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
        store.undo(); store.previewTask?.cancel()
        XCTAssertTrue(store.photos[0].parameters.regions.isEmpty)
    }

    @MainActor func testVisualReviewCannotAlterUnrequestedRegionChannel() async {
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
        XCTAssertEqual(store.photos[0].parameters.regions["person"]?.mean, [60, 1, 2])
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }

    @MainActor func testNewPersonRegionReviewCannotAlterUnrequestedColor() async {
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
        XCTAssertEqual(store.photos[0].parameters.regions["person"]?.mean, [60, 1, 2])
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }

    @MainActor func testNewPersonRegionCanRefineRequestedBrightness() async {
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
        XCTAssertEqual(store.photos[0].parameters.regions["person"]?.mean, [65, 1, 2])
        store.undo(); store.previewTask?.cancel()
        XCTAssertTrue(store.photos[0].parameters.regions.isEmpty)
    }

    @MainActor func testCancellingSuggestionBeforeJobIDStillCancelsServerJob() async throws {
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
        XCTAssertNil(result)
        XCTAssertEqual(cancelledID, "delayed-job")
    }

    @MainActor func testVisualReviewPreservesExplicitNumericRequest() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.2
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.exposure = 0.3
            return [AssistantChange(id: "original", params: altered, notes: [])]
        }, preserveExactValues: true)
        store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].parameters.exposure, 0.2)
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("指定的数值") })
    }

    @MainActor func testVisualReviewCannotAddAnUnrequestedParameter() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            var altered = prepared[0].parameters; altered.temperature = 0.4
            return [AssistantChange(id: "original", params: altered, notes: ["色温"])]
        })
        store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].parameters.exposure, 0.3)
        XCTAssertEqual(store.photos[0].parameters.temperature, 0)
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("未请求") })
    }

    @MainActor func testVisualReviewIsOneTransactionAndUndoRestoresOriginal() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: ["首轮曝光"])], error: nil)
        var reviews = 0
        await store.applyAssistantResult(job, items: items, review: { prepared in
            reviews += 1
            XCTAssertEqual(prepared[0].parameters.exposure, 0.3)
            var refined = prepared[0].parameters; refined.exposure = 0.35
            return [AssistantChange(id: "original", params: refined, notes: ["复看曝光"])]
        })
        store.previewTask?.cancel()
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(store.photos[0].parameters.exposure, 0.35)
        XCTAssertEqual(store.undoChanges.count, 1)
        store.undo(); store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
    }

    @MainActor func testVisualReviewCannotOverwriteChangesMadeWhileWaiting() async {
        let store = fixture(), items = store.photos
        var first = items[0].parameters; first.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "", selection: "none", changes: [
            AssistantChange(id: "original", params: first, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items, review: { prepared in
            store.photos[0].quality.denoise = true
            return []
        })
        store.previewTask?.cancel()
        XCTAssertTrue(store.photos[0].quality.denoise)
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
        XCTAssertTrue(store.undoChanges.isEmpty)
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("已跳过") })
    }

    @MainActor func testVisionConsentDefaultsOffAndIsScopedToProvider() {
        let store = WorkspaceStore()
        XCTAssertFalse(store.visionEnabled)
        store.visionConsentProvider = "codex"
        XCTAssertTrue(store.visionEnabled)
        store.assistantProvider = "claude"
        XCTAssertFalse(store.visionEnabled)
        store.visionConsentProvider = nil
        store.assistantProvider = "codex"
        XCTAssertFalse(store.visionEnabled)
        store.assistantProvider = "anthropic"
        store.visionConsentProvider = "anthropic"
        XCTAssertTrue(store.visionEnabled)
        store.assistantProvider = "codex"
        XCTAssertFalse(store.visionEnabled)
    }

    @MainActor private func fixture() -> WorkspaceStore {
        let store = WorkspaceStore()
        let image = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg", thumbnail: "/thumb.png",
                                  original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: image, assetID: "original")]
        store.currentID = "photo"
        return store
    }

    @MainActor func testUndoAIChangeDoesNotUndoQualityChangedDuringRequest() async {
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
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
        XCTAssertTrue(store.photos[0].quality.denoise, "撤销 AI 时不能撤销用户在等待期间更改的画质")
    }

    @MainActor func testReceiptTracksUndoAndRedo() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已调整", selection: "none",
            changes: [AssistantChange(id: "original", params: params, notes: ["曝光 0 → 0.3"])], error: nil)
        await store.applyAssistantResult(job, items: items); store.previewTask?.cancel()
        XCTAssertFalse(store.chatMessages.last!.wasUndone)
        store.undo(); store.previewTask?.cancel()
        XCTAssertTrue(store.chatMessages.last!.wasUndone)
        store.redo(); store.previewTask?.cancel()
        XCTAssertFalse(store.chatMessages.last!.wasUndone)
    }

    @MainActor func testCancelBeforeJobIDRejectsLateResult() async {
        let store = fixture(), items = store.photos
        store.chatting = true
        store.cancelChat()
        XCTAssertTrue(store.assistantCancellationRequested)
        var params = items[0].parameters; params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已调整", selection: "none",
            changes: [AssistantChange(id: "original", params: params, notes: [])], error: nil)
        await store.applyAssistantResult(job, items: items)
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
        XCTAssertTrue(store.undoChanges.isEmpty)
    }

    @MainActor func testAIUndoUsesSameStackAndRefusesStaleTarget() async {
        let store = fixture()
        store.change("曝光") { $0.exposure = 0.4 }; store.previewTask?.cancel()
        let items = store.photos, candidate = store.undoChanges.last!.id
        let job = AssistantJob(state: "done", reply: "准备撤销", selection: "none", changes: [
            AssistantChange(id: "original", params: items[0].parameters, notes: [],
                            operations: [AssistantOperation(kind: "undo", value: 0)])], error: nil)
        await store.applyAssistantResult(job, items: items, undoCandidate: candidate)
        store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
        XCTAssertEqual(store.redoChanges.count, 1)
        store.redo(); store.previewTask?.cancel()
        store.change("色温") { $0.temperature = 0.2 }; store.previewTask?.cancel()
        let latest = store.photos[0].snapshot
        await store.applyAssistantResult(job, items: items, undoCandidate: candidate)
        XCTAssertEqual(store.photos[0].snapshot, latest)
        XCTAssertTrue(store.chatMessages.last!.text.contains("没有操作"))
    }

    @MainActor func testAIUndoDoesNotUndoSliderStillBeingDragged() async {
        let store = fixture()
        store.change("曝光") { $0.exposure = 0.4 }; store.previewTask?.cancel()
        let items = store.photos, candidate = store.undoChanges.last!.id
        store.beginEditing("色温")
        store.update { $0.temperature = 0.2 }; store.previewTask?.cancel()
        let job = AssistantJob(state: "done", reply: "准备撤销", selection: "none", changes: [
            AssistantChange(id: "original", params: items[0].parameters, notes: [],
                            operations: [AssistantOperation(kind: "undo", value: 0)])], error: nil)
        await store.applyAssistantResult(job, items: items, undoCandidate: candidate)
        XCTAssertEqual(store.photos[0].parameters.exposure, 0.4)
        XCTAssertEqual(store.photos[0].parameters.temperature, 0.2)
        XCTAssertEqual(store.undoChanges.count, 2)
        XCTAssertTrue(store.chatMessages.last!.text.contains("没有操作"))
    }

    @MainActor func testPreparedOperationCannotOverwriteNewerQuality() async {
        let store = fixture(), source = store.photos[0]
        var params = source.parameters; params.exposure = 0.5
        let prepared = try! await store.prepareOperation(.parameters(params, name: "AI 调整", notes: []), on: source)
        store.photos[0].quality.denoise = true
        XCTAssertFalse(store.commitPrepared(prepared, expected: source.snapshot))
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
        XCTAssertTrue(store.photos[0].quality.denoise)
    }

    @MainActor func testFailedMultiStepRequestCannotClaimOrApplySuccess() async {
        let store = fixture(), items = store.photos
        var params = items[0].parameters; params.exposure = 0.3
        let job = AssistantJob(state: "done", reply: "已经完成", selection: "none", changes: [
            AssistantChange(id: "original", params: params, notes: ["曝光"],
                            operations: [AssistantOperation(kind: "match", value: 0)])], error: nil)
        await store.applyAssistantResult(job, items: items)
        XCTAssertEqual(store.photos[0].parameters.exposure, 0)
        XCTAssertTrue(store.undoChanges.isEmpty)
        XCTAssertTrue(store.chatMessages.last!.text.contains("没有应用"))
        XCTAssertFalse(store.chatMessages.last!.text.contains("已经完成"))
    }

    @MainActor func testNoOperationCannotClaimItChangedPhoto() async {
        let store = fixture(), items = store.photos
        let job = AssistantJob(state: "done", reply: "我已经把天空调蓝了。", selection: "none", changes: [], error: nil)
        await store.applyAssistantResult(job, items: items)
        XCTAssertTrue(store.undoChanges.isEmpty)
        XCTAssertTrue(store.chatMessages.last!.text.contains("没有执行调整"))
        XCTAssertFalse(store.chatMessages.last!.text.contains("调蓝了"))
    }

    @MainActor func testBatchSkipsChangedPhotoAndUndoPreservesItsNewEdit() async {
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
        XCTAssertEqual(store.photos[0].parameters.exposure, 0.7)
        XCTAssertEqual(store.photos[1].parameters.exposure, 0.4)
        XCTAssertEqual(store.chatMessages.last!.affectedPhotos, ["second.jpg"])
        XCTAssertTrue(store.chatMessages.last!.notes.contains { $0.contains("fixture.jpg") && $0.contains("已跳过") })
        store.undo(); store.previewTask?.cancel()
        XCTAssertEqual(store.photos[0].parameters.exposure, 0.7)
        XCTAssertEqual(store.photos[1].parameters.exposure, 0)
    }
}
