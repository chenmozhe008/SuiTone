import Foundation
import Testing
@testable import PhotoEdit

@MainActor @Suite struct RecipeCompatibilityTests {
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
