import Foundation
import Testing
@testable import PhotoEdit

/// 图集（导入批次）要能跨重启：关掉应用再打开，照片、调整、历史记录都还在。
@MainActor @Suite struct LibraryPersistenceTests {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGO0qdjCgA0wYRUdtBIAHQ8BeIKmlrAAAAAASUVORK5CYII=")!

    private var engineRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture(_ names: [String]) throws -> (URL, [URL]) {
        let folder = engineRoot.appendingPathComponent("tmp/library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = names.map { folder.appendingPathComponent($0 + ".png") }
        for path in paths { try Self.png.write(to: path) }
        return (folder, paths)
    }

    /// 每个测试一个 store，图集写在测试自己的目录里，并行跑也不打架。
    private func makeStore(_ folder: URL) -> WorkspaceStore {
        let store = WorkspaceStore(engine: EngineClient(root: engineRoot))
        store.libraryDirectory = folder.appendingPathComponent("catalog")
        try? FileManager.default.removeItem(at: store.libraryPath)
        return store
    }

    private func waitUntil(_ seconds: Double = 30, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { try? await Task.sleep(for: .milliseconds(200)) }
    }

    @Test @MainActor func testAlbumSurvivesRestartWithAdjustmentsAndHistory() async throws {
        let (folder, paths) = try fixture(["first", "second"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = makeStore(folder)
        first.importURLs(paths)
        await first.importTask?.value
        #expect(first.photos.count == 2)
        let album = try #require(first.albums.first)
        #expect(album.photos.count == 2)
        #expect(first.currentAlbumID == album.id)

        first.change("测试曝光") { $0.exposure = 0.5; $0.saturation = 1.4 }
        #expect(first.photos[0].parameters.exposure == 0.5)
        #expect(first.albumSteps.count == 1)
        try await Task.sleep(for: .milliseconds(900))   // 等防抖写盘

        // 重启：新实例只读磁盘上的图集（沿用同一个目录，不能清）
        let second = WorkspaceStore(engine: EngineClient(root: engineRoot))
        second.libraryDirectory = first.libraryDirectory
        second.loadLibrary()
        let restored = try #require(second.albums.first)
        #expect(second.albums.count == 1)
        #expect(restored.photos.count == 2)
        #expect(restored.steps.count == 1)
        #expect(restored.photos[0].parameters.exposure == 0.5)

        second.openAlbum(restored)
        await waitUntil { second.photos.count == 2 && second.photos.allSatisfy(\.ready) }
        #expect(second.photos.count == 2)
        #expect(second.currentAlbumID == restored.id)
        let reopened = try #require(second.photos.first)
        #expect(reopened.parameters.exposure == 0.5)
        #expect(reopened.parameters.saturation == 1.4)
        #expect(second.albumSteps.count == 1)
        second.previewTask?.cancel()
    }

    @Test @MainActor func testDeletingAlbumLeavesPhotoFilesAlone() async throws {
        let (folder, paths) = try fixture(["only"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = makeStore(folder)
        store.importURLs(paths)
        await store.importTask?.value
        let album = try #require(store.albums.first)

        store.deleteAlbum(album.id)
        #expect(store.albums.isEmpty)
        #expect(store.photos.isEmpty && store.currentAlbumID == nil)
        #expect(FileManager.default.fileExists(atPath: paths[0].path))
        store.previewTask?.cancel()
    }

    @Test @MainActor func testRevertingToAStepBringsThatLookBack() async throws {
        let (folder, paths) = try fixture(["step"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = makeStore(folder)
        store.importURLs(paths)
        await store.importTask?.value
        store.change("第一步") { $0.exposure = 0.3 }
        store.change("第二步") { $0.exposure = 0.9 }
        #expect(store.albumSteps.count == 2)
        let firstStep = try #require(store.albumSteps.first)

        store.revertToStep(firstStep)
        #expect(try #require(store.photos.first).parameters.exposure == 0.3)
        // 回到这一步之后，后面那步不再留着
        #expect(store.albumSteps.count == 1)
        store.previewTask?.cancel()
    }
}
