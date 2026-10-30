import Foundation
import Testing
@testable import PhotoEdit

@MainActor @Suite struct RecipeCompatibilityTests {
    @Test func testManualSelectionAndSlidersRoundTripInRecipe() throws {
        let key = "selection-123456789abc"
        var params = AdjustmentParameters()
        params.manualMasks[key] = RemovalOperation(box: [0.1, 0.2, 0.4, 0.6], strokes: [[[0.2, 0.3], [0.3, 0.5]]], radius: 0.02)
        var adjustment = LocalAdjustment(); adjustment.exposure = 0.4
        params.local[key] = adjustment
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let restored = try decoder.decode(AdjustmentParameters.self, from: encoder.encode(params))
        #expect(restored.manualMasks[key]?.strokes == params.manualMasks[key]?.strokes)
        #expect(restored.local[key]?.exposure == 0.4)
    }
    @Test func testSavedReferenceMatchRemainsIdentifiableWithoutReferenceFile() throws {
        let region = RegionAdjustment(mean: [60, 1, 2], sourceMean: [50, 1, 2], chromaScale: [1, 1],
            lumaX: [0, 100], lumaY: [0, 100], referenceLumaMean: 50, strength: 1, referenceCount: 1)
        var params = AdjustmentParameters(); params.regions["sky"] = region
        let restored = try JSONDecoder().decode(AdjustmentParameters.self, from: JSONEncoder().encode(params))
        #expect(restored.hasReferenceMatch)
        params.regions["sky"]?.referenceCount = 0
        #expect(!params.hasReferenceMatch)
    }
    @Test func testRecipeWithoutExportFormatStillLoadsItsExistingOptions() throws {
        let source = #"{"version":1,"photos":[],"options":{"info_bar":true,"place":"测试地点","lut":false,"denoise":true,"scale":2}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let recipe = try decoder.decode(ProjectRecipe.self, from: Data(source.utf8))
        #expect(recipe.options.format == nil)
        #expect(recipe.options.infoBar)
        #expect(recipe.options.denoise)
        #expect(recipe.options.place == "测试地点")
        #expect(recipe.options.scale == 2)
    }

    @Test func testOldRecipeQualityMigratesAndNewRecipeStoresItPerPhoto() throws {
        let source = #"{"version":1,"photos":[{"path":"/fixture.jpg","params":{},"operations":[]}],"options":{"denoise":true,"scale":2}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var recipe = try decoder.decode(ProjectRecipe.self, from: Data(source.utf8))
        let quality = recipe.photos[0].restoredQuality(options: recipe.options)
        #expect(quality == QualitySettings(denoise: true, scale: 2))
        recipe.photos[0].quality = quality
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(recipe)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let options = json["options"] as! [String: Any]
        #expect(options["denoise"] == nil)
        #expect(options["scale"] == nil)
        let restored = try decoder.decode(ProjectRecipe.self, from: data)
        #expect(restored.photos[0].restoredQuality(options: restored.options) == quality)
    }

    @Test @MainActor func testQualityUndoRedoIsIndependentOfColorEdits() async {
        let store = WorkspaceStore()
        let imported = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg", thumbnail: "/thumb.png",
            original: "/source.png", width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: imported, assetID: "original")]
        store.currentID = "photo"
        store.photos[0].parameters.exposure = 0.7
        let before = store.capture(store.photos)
        store.photos[0].quality = QualitySettings(denoise: true, scale: 4)
        store.recordChange("调整画质", before: before)
        store.undo(); store.previewTask?.cancel()
        #expect(store.current?.quality == QualitySettings())
        #expect(store.current?.parameters.exposure == 0.7)
        store.redo(); store.previewTask?.cancel()
        #expect(store.current?.quality == QualitySettings(denoise: true, scale: 4))
        #expect(store.current?.parameters.exposure == 0.7)
    }
}
