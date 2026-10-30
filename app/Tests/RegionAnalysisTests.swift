import Foundation
import Testing
@testable import PhotoEdit

@MainActor @Suite struct RegionAnalysisTests {
    @Test func failedAnalysisCanBeRetriedAndDoesNotRestartInFlight() async {
        let store = WorkspaceStore(engine: EngineClient(root: URL(fileURLWithPath: "/nonexistent-suitone-test")))
        let photo = ImportedPhoto(id: "photo", path: "/unused", name: "photo", thumbnail: "", original: "", width: 1, height: 1, similarTo: nil)
        var record = PhotoRecord(imported: photo, assetID: photo.id)
        record.ready = true
        store.photos = [record]; store.currentID = photo.id
        store.loadAnalysis()
        let request = store.analysisRequestID
        store.loadAnalysis()
        #expect(store.analysisRequestID == request)
        await store.analysisTask?.value
        #expect(store.analysis == nil)
        #expect(store.analysisError != nil)
        #expect(store.analysisTask == nil)
        store.loadAnalysis()
        #expect(store.analysisError == nil)
        #expect(store.analysisRequestID != request)
        await store.analysisTask?.value
        #expect(store.analysisError != nil)
    }
}
