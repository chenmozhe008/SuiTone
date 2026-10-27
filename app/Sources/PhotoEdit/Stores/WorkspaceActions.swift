import AppKit

extension WorkspaceStore {
    func loadStyleTiles() {
        guard let photo=current, photo.ready else{return}
        styleTileTask?.cancel()
        styleTileTask=Task {
            do {
                struct Tiles:Decodable{var tiles:[String:String]}
                let result:Tiles=try await engine.request("style-tiles",body:["id":photo.assetID])
                guard !Task.isCancelled,current?.assetID==photo.assetID else{return}
                styleTiles=result.tiles
            } catch {if !Task.isCancelled {status="风格缩略图未就绪，可直接点击试用"}}
        }
    }

    func applyStyle(_ style: String) {
        guard !controlsBlocked, !targets.isEmpty else { return }
        finishEditing()
        let items = targets, before = capture(items)
        batchWorking = true; progressDone = 0; progressTotal = items.count; showOriginal = false
        batchTask = Task {
            defer {
                recordChange("应用\(StylePreset.all.first(where: { $0.id == style })?.title ?? "风格")", before: before)
                batchWorking = false; batchTask = nil
            }
            for photo in items {
                if Task.isCancelled { status = "已停止，已完成的效果可以撤销"; return }
                do {
                    status = "生成风格 \(progressDone + 1)/\(progressTotal)"
                    let result: SmartResponse = try await engine.request("smart", body: ["id": photo.assetID, "style": style, "quality": try EngineClient.object(photo.quality)])
                    guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { continue }
                    photos[i].parameters = result.params; photos[i].lookName = result.title
                    photos[i].notes = result.notes; photos[i].previewPath = result.preview; photos[i].ready = true
                    progressDone += 1
                } catch { self.error = error.localizedDescription; return }
            }
            status = "已完成 \(items.count) 张 · 每张按自身画面调整，可整批撤销"
        }
    }

    func match() {
        guard !controlsBlocked, !targets.isEmpty, !references.isEmpty else { return }
        finishEditing()
        let items = targets, before = capture(items)
        let referenceIDs = references.map(\.id), scopes = referenceScopes, only = matchOnly
        batchWorking = true; progressDone = 0; progressTotal = items.count; showOriginal = false
        batchTask = Task {
            defer { recordChange("参考图匹配", before: before); batchWorking = false; batchTask = nil }
            for photo in items {
                if Task.isCancelled { return }
                do {
                    status = "按区域匹配 \(progressDone + 1)/\(progressTotal)"
                    var body: [String: Any] = ["id": photo.assetID, "references": referenceIDs, "params": try EngineClient.object(photo.parameters), "reference_scopes": scopes]
                    if only != "all" { body["only"] = only }
                    let result: MatchResponse = try await engine.request("match", body: body)
                    guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { continue }
                    photos[i].parameters = result.params; photos[i].lookName = result.learned.isEmpty ? photo.lookName : "参考匹配"
                    photos[i].notes = result.notes + result.learned.map { "已学习" + RegionNames.title($0) + "的颜色与影调" }
                    let response: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID, "params": try EngineClient.object(result.params), "quality": try EngineClient.object(photo.quality)])
                    photos[i].previewPath = response.preview; progressDone += 1
                    if currentID == photo.id { matchNotes = result.notes }
                } catch { self.error = error.localizedDescription; return }
            }
            status = "参考匹配完成 · 没有共同可靠区域的部分保持原样"
        }
    }

    func synchronize(keepDehaze: Bool = true) {
        finishEditing()
        guard let source = current else { return }
        let items = targets.filter { $0.id != source.id }, before = capture(items)
        for i in photos.indices where items.contains(where: { $0.id == photos[i].id }) {
            let localDehaze = photos[i].parameters.dehazeAmt, localAuto = photos[i].parameters.autoDehaze
            photos[i].parameters = source.parameters
            if keepDehaze { photos[i].parameters.dehazeAmt = localDehaze; photos[i].parameters.autoDehaze = localAuto }
            photos[i].lookName = source.lookName; photos[i].notes = source.notes; photos[i].previewPath = nil
        }
        recordChange("同步当前调整", before: before)
        status = "已同步 \(items.count) 张 · 各自的去雾强度保留"
        refreshGrid()
    }

    func refreshGrid() {
        let ids = included.map(\.id)
        Task {
            for id in ids {
                guard let photo = photos.first(where: { $0.id == id }), photo.ready, photo.previewPath == nil else { continue }
                do {
                    let result: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID, "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
                    if let i = photos.firstIndex(where: { $0.id == id }), photos[i].parameters == photo.parameters,
                       photos[i].quality == photo.quality, photos[i].assetID == photo.assetID {
                        photos[i].previewPath = result.preview
                        if photos[i].parameters.autoDehaze == true { photos[i].parameters.dehazeAmt = result.dehazeAmt }
                    }
                } catch { self.error = error.localizedDescription; return }
            }
        }
    }

}
