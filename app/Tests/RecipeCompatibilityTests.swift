import XCTest
@testable import PhotoEdit

final class RecipeCompatibilityTests: XCTestCase {
    func testRecipeWithoutExportFormatStillLoadsItsExistingOptions() throws {
        let source = #"{"version":1,"photos":[],"options":{"info_bar":true,"place":"测试地点","lut":false,"denoise":true,"scale":2}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let recipe = try decoder.decode(ProjectRecipe.self, from: Data(source.utf8))
        XCTAssertNil(recipe.options.format)
        XCTAssertTrue(recipe.options.infoBar)
        XCTAssertTrue(recipe.options.denoise)
        XCTAssertEqual(recipe.options.place, "测试地点")
        XCTAssertEqual(recipe.options.scale, 2)
    }

    func testOldRecipeQualityMigratesAndNewRecipeStoresItPerPhoto() throws {
        let source = #"{"version":1,"photos":[{"path":"/fixture.jpg","params":{},"operations":[]}],"options":{"denoise":true,"scale":2}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var recipe = try decoder.decode(ProjectRecipe.self, from: Data(source.utf8))
        let quality = recipe.photos[0].restoredQuality(options: recipe.options)
        XCTAssertEqual(quality, QualitySettings(denoise: true, scale: 2))
        recipe.photos[0].quality = quality
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(recipe)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let options = json["options"] as! [String: Any]
        XCTAssertNil(options["denoise"])
        XCTAssertNil(options["scale"])
        let restored = try decoder.decode(ProjectRecipe.self, from: data)
        XCTAssertEqual(restored.photos[0].restoredQuality(options: restored.options), quality)
    }

    @MainActor func testQualityUndoRedoIsIndependentOfColorEdits() async {
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
        XCTAssertEqual(store.current?.quality, QualitySettings())
        XCTAssertEqual(store.current?.parameters.exposure, 0.7)
        store.redo(); store.previewTask?.cancel()
        XCTAssertEqual(store.current?.quality, QualitySettings(denoise: true, scale: 4))
        XCTAssertEqual(store.current?.parameters.exposure, 0.7)
    }
}
