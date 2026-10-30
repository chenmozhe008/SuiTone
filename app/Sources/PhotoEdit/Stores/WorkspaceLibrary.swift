import Foundation

/// 图集里的一张照片：源文件路径 + 这一刻的调整状态。
/// 不存缩略图和预览图——它们都在引擎的会话临时目录里，重启后会被清掉。
struct LibraryPhoto: Codable, Equatable {
    var path: String
    var assetID: String
    var parameters: AdjustmentParameters
    var operations: [RemovalOperation]
    var quality: QualitySettings
    var lookName: String
    var starred = false
    var excluded = false
}

/// 图集里的一步改动：这一步做完之后，涉及到的照片是什么样。
struct LibraryStep: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var label: String
    var states: [String: LibraryPhoto]
}

/// 一次导入形成的图集。关掉应用再打开还在，跟 Lightroom 目录里的条目一个意思。
struct LibraryAlbum: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    /// 导入来源（文件夹或照片所在目录），用来区分同名图集
    var source: String
    var createdAt: Date
    var updatedAt: Date
    /// 列表里的缩略图直接用源文件，重启后依然有效
    var cover: String?
    var photos: [LibraryPhoto]
    /// 这个图集的改动记录，最新的在最后
    var steps: [LibraryStep]
}

extension WorkspaceStore {
    // MARK: - 存盘位置

    /// `~/Library/Application Support/SuiTone/library.json`：开发模式和发行包共用一处，
    /// 不放在 engine.root，因为开发模式下那是项目目录。
    /// 单元测试跑起来实例化 Store 时也会走到这里，写进临时目录，别把用户的图集盖掉。
    static var libraryFile: URL {
        let environment = ProcessInfo.processInfo.environment
        let name = ProcessInfo.processInfo.processName
        let testing = name == "swiftpm-testing-helper" || name.hasSuffix("PackageTests")
            || name.hasSuffix(".xctest") || Bundle.main.bundlePath.hasSuffix(".xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
        if testing {
            return FileManager.default.temporaryDirectory.appendingPathComponent("SuiTone-tests/library.json")
        }
        if let override = environment["SUITONE_LIBRARY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("library.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SuiTone/library.json", isDirectory: false)
    }

    /// 实际用的文件：测试里由 `libraryDirectory` 指定，正常运行就是 `Self.libraryFile`。
    var libraryPath: URL {
        libraryDirectory.map { $0.appendingPathComponent("library.json") } ?? Self.libraryFile
    }

    // MARK: - 读写

    func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryPath) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([LibraryAlbum].self, from: data) else { return }
        albums = saved.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 写盘（原子替换）。图集最多几十个、每张照片只有参数，文件很小，直接覆盖不会卡。
    func writeLibrary() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let url = libraryPath
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(albums).write(to: url, options: .atomic)
        } catch { status = "图集记录未能保存：\(error.localizedDescription)" }
    }

    /// 拖动滑块时不要每次都写盘：停下来半秒再存。
    func scheduleLibrarySave() {
        libraryTask?.cancel()
        libraryTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeLibrary()
        }
    }

    /// 退出前把还没落盘的那一次改动写下去，免得刚改完就关掉丢记录。
    func flushLibrary() {
        libraryTask?.cancel(); libraryTask = nil
        guard !albums.isEmpty else { return }
        writeLibrary()
    }

    // MARK: - 当前图集

    var currentAlbum: LibraryAlbum? { albums.first { $0.id == currentAlbumID } }

    /// 图集名：一批照片来自同一个文件夹就用文件夹名，否则用张数。
    func albumTitle(for urls: [URL]) -> String {
        let folders = Set(urls.map { $0.hasDirectoryPath ? $0.lastPathComponent : $0.deletingLastPathComponent().lastPathComponent })
        if folders.count == 1, let name = folders.first, !name.isEmpty { return name }
        if urls.count == 1, let only = urls.first { return only.deletingPathExtension().lastPathComponent }
        return "\(photos.count) 张照片"
    }

    func libraryPhoto(_ snapshot: EditSnapshot, id: String) -> LibraryPhoto? {
        guard let photo = photos.first(where: { $0.id == id }) else { return nil }
        return LibraryPhoto(path: photo.imported.path, assetID: snapshot.assetID, parameters: snapshot.parameters,
                            operations: snapshot.operations, quality: snapshot.quality,
                            lookName: snapshot.lookName, starred: photo.starred, excluded: photo.excluded)
    }

    /// 把工作区里现在的样子写回当前图集。
    func syncAlbum() {
        guard let index = albums.firstIndex(where: { $0.id == currentAlbumID }) else { return }
        let states = photos.map { photo in
            LibraryPhoto(path: photo.imported.path, assetID: photo.assetID, parameters: photo.parameters,
                         operations: photo.operations, quality: photo.quality, lookName: photo.lookName,
                         starred: photo.starred, excluded: photo.excluded)
        }
        guard !states.isEmpty else { return }
        albums[index].photos = states
        albums[index].cover = states.first?.path
        albums[index].updatedAt = Date()
        albums[index].steps = albumSteps
        scheduleLibrarySave()
    }

    /// 记一步改动。跟撤销栈并行：撤销栈只在本次运行有效，这里写进了图集，重启后还能看到、能点回去。
    @discardableResult func noteStep(_ label: String, after: [String: EditSnapshot]) -> String? {
        guard currentAlbumID != nil else { return nil }
        var states: [String: LibraryPhoto] = [:]
        for (id, snapshot) in after {
            if let saved = libraryPhoto(snapshot, id: id) { states[id] = saved }
        }
        guard !states.isEmpty else { return nil }
        let step = LibraryStep(id: UUID().uuidString, date: Date(), label: label, states: states)
        albumSteps.append(step)
        if albumSteps.count > 300 { albumSteps.removeFirst(albumSteps.count - 300) }
        syncAlbum()
        return step.id
    }

    /// 导入完成：第一批照片开一个新图集；往已有工作区里添照片就并进当前图集。
    func adoptImportedPhotos(intoNewAlbum: Bool, title: String, source: String) {
        guard !photos.isEmpty else { return }
        let paths = Set(photos.map { $0.imported.path })
        // 同一批照片再导入一次，不该在左边多出一条一模一样的图集。
        if let existing = albums.first(where: { Set($0.photos.map(\.path)) == paths }) {
            currentAlbumID = existing.id
            albumSteps = existing.steps
            albums.removeAll { $0.id == existing.id }
            albums.insert(existing, at: 0)
            syncAlbum()
            return
        }
        if intoNewAlbum || currentAlbumID == nil {
            var album = LibraryAlbum(id: UUID().uuidString, title: title, source: source,
                                     createdAt: Date(), updatedAt: Date(), cover: photos.first?.imported.path,
                                     photos: [], steps: [])
            album.photos = photos.map { photo in
                LibraryPhoto(path: photo.imported.path, assetID: photo.assetID, parameters: photo.parameters,
                             operations: photo.operations, quality: photo.quality, lookName: photo.lookName,
                             starred: photo.starred, excluded: photo.excluded)
            }
            albums.insert(album, at: 0)
            currentAlbumID = album.id
            albumSteps = []
        }
        syncAlbum()
    }

    // MARK: - 打开 / 删除

    /// 打开一个图集：重新导入源文件，再把存下的调整盖上去。
    func openAlbum(_ album: LibraryAlbum) {
        guard !controlsBlocked else { return }
        let existing = Set(photos.map { $0.imported.path })
        let missing = album.photos.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            error = "有 \(missing.count) 张照片已经不在原来的位置：\n" + missing.prefix(5).map(\.path).joined(separator: "\n")
                + (missing.count > 5 ? "\n…" : "")
            return
        }
        if album.id == currentAlbumID, existing == Set(album.photos.map(\.path)) {
            syncAlbum(); return
        }
        finishEditing(); busy = true; status = "正在打开「\(album.title)」…"
        Task {
            defer { busy = false }
            do {
                let result: ImportResponse = try await engine.request("import", body: ["paths": album.photos.map(\.path)])
                var records: [PhotoRecord] = []
                for item in result.photos {
                    guard let saved = album.photos.first(where: { $0.path == item.path }) else { continue }
                    struct Restored: Decodable { var id: String; var params: AdjustmentParameters }
                    var restored: Restored?
                    if !(saved.operations.isEmpty && saved.parameters == AdjustmentParameters()) {
                        restored = try? await engine.request("restore", body: ["path": item.path,
                                                                              "params": try EngineClient.object(saved.parameters),
                                                                              "operations": try saved.operations.map(EngineClient.object)])
                    }
                    var record = PhotoRecord(imported: item, assetID: restored?.id ?? item.id)
                    if let restored { record.parameters = restored.params }
                    record.operations = saved.operations; record.quality = saved.quality
                    record.lookName = saved.lookName; record.starred = saved.starred; record.excluded = saved.excluded
                    record.ready = true
                    records.append(record)
                }
                guard !records.isEmpty else { throw EngineError(message: "这个图集里的照片都读不出来了") }
                photos = records; undoChanges = []; redoChanges = []
                currentAlbumID = album.id; albumSteps = album.steps
                selectedIDs = Set(records.prefix(1).map(\.id))
                grid = records.count > 1
                activate(records.first?.id); refreshGrid()
                status = "已打开「\(album.title)」· \(records.count) 张"
                if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 删除一个图集：只删记录，不动磁盘上的照片。
    func deleteAlbum(_ id: String) {
        guard let album = albums.first(where: { $0.id == id }) else { return }
        albums.removeAll { $0.id == id }
        writeLibrary()
        if currentAlbumID == id {
            currentAlbumID = nil; albumSteps = []
            photos = []; references = []; selectedIDs = []; currentID = nil
            analysis = nil; overlay = ""; undoChanges = []; redoChanges = []
            status = "已移除图集「\(album.title)」，照片文件未删除"
        }
    }

    func renameAlbum(_ id: String, to title: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        albums[index].title = trimmed
        albums[index].updatedAt = Date()
        writeLibrary()
    }

    /// 清空工作区，准备导入新的一批照片（原来的图集留在列表里）。
    func startFreshWorkspace() {
        guard !controlsBlocked else { return }
        finishEditing()
        syncAlbum()
        photos = []; references = []; selectedIDs = []; currentID = nil
        currentAlbumID = nil; albumSteps = []
        analysis = nil; overlay = ""; undoChanges = []; redoChanges = []; grid = false
        status = "已新建图集，请选择照片"
        chooseImport()
    }

    // MARK: - 历史

    /// 回到某一步之后的样子（撤销栈不是必须的，这里直接按存下的状态摆回去）。
    func revertToStep(_ step: LibraryStep) {
        guard !controlsBlocked else { return }
        finishEditing()
        var states: [String: EditSnapshot] = [:]
        for (id, saved) in step.states {
            states[id] = EditSnapshot(assetID: saved.assetID, parameters: saved.parameters, operations: saved.operations,
                                      label: step.label, lookName: saved.lookName, notes: [], quality: saved.quality)
        }
        guard !states.isEmpty else { return }
        applyStates(states)
        // 截断到这步为止：后面的步骤还留在列表里也没意义，用户可能想改路线重来。
        if let index = albumSteps.firstIndex(where: { $0.id == step.id }) {
            albumSteps.removeSubrange((index + 1)...)
        }
        undoChanges = []; redoChanges = []
        syncAlbum()
        status = "已回到「\(step.label)」"
    }

    func deleteStep(_ step: LibraryStep) {
        albumSteps.removeAll { $0.id == step.id }
        syncAlbum()
        status = "已删除一条历史记录"
    }

    func clearSteps() {
        guard !albumSteps.isEmpty else { return }
        albumSteps = []
        syncAlbum()
        status = "已清空历史记录，照片保持现在的样子"
    }
}
