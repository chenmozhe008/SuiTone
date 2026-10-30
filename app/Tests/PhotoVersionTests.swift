import Foundation
import Testing
@testable import PhotoEdit

/// AI 改图页的「版本预览」：以前这里有两个坑，都会让画面看起来不对。
/// 1) 版本条第一项「原图」给的是缩略图，点上画布就是一张小图拉满屏，糊的；
/// 2) 换照片／换图集时没清 `versionPreview`，画布会继续显示上一张的版本图。
@MainActor @Suite struct PhotoVersionTests {
    @MainActor private func store() -> WorkspaceStore {
        let store = WorkspaceStore()
        let imported = ImportedPhoto(id: "photo", path: "/fixture.jpg", name: "fixture.jpg",
                                     thumbnail: "/thumb-small.png", original: "/source-full.png",
                                     width: 1200, height: 800, similarTo: nil)
        store.photos = [PhotoRecord(imported: imported, assetID: "original")]
        store.currentID = "photo"
        return store
    }

    @Test func originalVersionPointsAtTheFullSizeFile() {
        let store = self.store()
        let versions = store.photoVersions
        #expect(versions.first?.title == "原图")
        #expect(versions.first?.path == "/source-full.png")   // 画布用这张
        #expect(versions.first?.thumb == "/thumb-small.png")  // 版本条用这张
    }

    @Test func generatedVersionsUseTheSamePathForBoth() {
        let store = self.store()
        store.photos[0].operations = [RemovalOperation(box: [0, 0, 1, 1], classes: nil, keep: nil,
                                                      generated: "/generated-1.png")]
        let versions = store.photoVersions
        #expect(versions.count == 2)
        #expect(versions[1].path == "/generated-1.png" && versions[1].thumb == "/generated-1.png")
    }

    @Test func switchingPhotoDropsTheVersionPreview() {
        let store = self.store()
        store.versionPreview = "/generated-1.png"
        store.activate(nil)
        #expect(store.versionPreview == nil)
    }
}
