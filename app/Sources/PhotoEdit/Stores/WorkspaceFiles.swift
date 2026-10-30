import AppKit

extension WorkspaceStore {
    func chooseImport(reference: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !reference; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = reference ? "选择参考图，匹配色彩与影调" : "选择照片或文件夹"
        if panel.runModal() == .OK { importURLs(panel.urls, reference: reference) }
    }

    func importURLs(_ urls: [URL], reference: Bool = false) {
        guard !controlsBlocked else { return }
        // 空工作区里导入＝开一个新图集；已经有照片时再导入，照片并进当前图集。
        let startsNewAlbum = photos.isEmpty
        finishEditing(); importing = true; progressDone = 0; progressTotal = 0
        status = reference ? "正在读取参考图…" : "正在查找照片…"
        importTask = Task {
            defer {
                importing = false; importTask = nil
            }
            do {
                struct Scanned: Decodable { var paths: [String]; var errors: [String] }
                let scan: Scanned = try await engine.request("scan", body: ["paths": urls.map(\.path)])
                progressTotal = scan.paths.count
                var failures = scan.errors
                for path in scan.paths {
                    if Task.isCancelled { status = "已停止导入，已经读入的照片保留"; break }
                    status = "\(reference ? "读取参考" : "导入照片") \(progressDone + 1)/\(progressTotal)"
                    let result: ImportResponse = try await engine.request("import", body: ["paths": [path]])
                    failures += result.errors
                    for item in result.photos {
                        if reference {
                            if !references.contains(where: { $0.id == item.id }) { references.append(item) }
                        } else if !photos.contains(where: { $0.id == item.id }) {
                            var record = PhotoRecord(imported: item, assetID: item.id)
                            record.ready = true; photos.append(record)
                            if currentID == nil { currentID = item.id; selectedIDs = [item.id] }
                        }
                    }
                    progressDone += 1
                }
                if !Task.isCancelled { status = reference ? "参考图已就绪" : "照片已导入 · \(included.count) 张" }
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
                if !reference, photos.count > 1, inspectorTab != "repair" { grid = true }
                if !reference {
                    if !Task.isCancelled {
                        adoptImportedPhotos(intoNewAlbum: startsNewAlbum, title: albumTitle(for: urls),
                                            source: urls.first.map { $0.hasDirectoryPath ? $0.path : $0.deletingLastPathComponent().path } ?? "")
                    }
                    refreshGrid(); loadStyleTiles()
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func stopBatch() {
        importTask?.cancel(); batchTask?.cancel()
    }

    func export() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.message = "单张直接导出到这里；多张会新建一个 SuiTone-时间 文件夹，已有文件不会被覆盖"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let items = targets
        guard !items.isEmpty else { return }
        busy = true; showExportOptions = false; status = "正在全尺寸导出…"
        Task {
            defer { busy = false }
            let progressTask = Task {
                while !Task.isCancelled {
                    if let (done,total,name) = try? await engine.progress(), total > 0 {
                        status = "全尺寸导出 \(min(done + 1,total))/\(total) · \(name)"
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { progressTask.cancel() }
            do {
                var options = exportOptions; options.lut = false
                let body: [String: Any] = ["items": try items.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters), "quality": try EngineClient.object($0.quality)] },
                                           "destination": destination.path, "options": try EngineClient.object(options)]
                let result: ExportResponse = try await engine.request("export", body: body)
                lastExport = result.directory
                status = result.files.count == 1 ? "已导出 1 张到所选位置" : "已导出 \(result.files.count) 张到新文件夹"
            } catch { self.error = error.localizedDescription }
        }
    }

    func saveProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "照片调整-\(Int(Date().timeIntervalSince1970)).photoedit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = ProjectRecipe(photos: photos.map { ProjectPhoto(path: $0.imported.path, params: $0.parameters, operations: $0.operations, quality: $0.quality) }, options: exportOptions)
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(project).write(to: url, options: .withoutOverwriting)
            status = "已保存调整记录，原图保持不变"
        } catch { self.error = error.localizedDescription }
    }

    func openProject(_ inputURL: URL? = nil) {
        guard !controlsBlocked else { return }
        let url: URL
        if let inputURL { url = inputURL }
        else {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                let project = try decoder.decode(ProjectRecipe.self, from: Data(contentsOf: url))
                guard project.version == 1 else { throw EngineError(message: "无法读取此版本的调整记录") }
                let result: ImportResponse = try await engine.request("import", body: ["paths": project.photos.map(\.path)])
                var records: [PhotoRecord] = []
                for item in result.photos {
                    guard let saved = project.photos.first(where: { $0.path == item.path }) else { continue }
                    struct Restored: Decodable { var id: String; var params: AdjustmentParameters }
                    let response: Restored = try await engine.request("restore", body: ["path": item.path, "params": try EngineClient.object(saved.params), "operations": try saved.operations.map(EngineClient.object)])
                    var record = PhotoRecord(imported: item, assetID: response.id)
                    record.parameters = response.params; record.operations = saved.operations
                    record.quality = saved.restoredQuality(options: project.options)
                    record.lookName = "已保存的调整"; record.ready = true; records.append(record)
                }
                photos = records; exportOptions = project.options; undoChanges = []; redoChanges = []
                currentAlbumID = nil; albumSteps = []
                adoptImportedPhotos(intoNewAlbum: true, title: url.deletingPathExtension().lastPathComponent,
                                    source: url.deletingLastPathComponent().path)
                selectedIDs = Set(records.prefix(1).map(\.id)); activate(records.first?.id); grid = records.count > 1; refreshGrid()
                if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
            } catch { self.error = error.localizedDescription }
        }
    }
}
