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
        runPhotoOperation(.style(style), items: targets,
            label: "应用\(StylePreset.all.first(where: { $0.id == style })?.title ?? "风格")")
    }

    func match() {
        guard !references.isEmpty else { return }
        runPhotoOperation(.match(references: references.map(\.id), scopes: referenceScopes, only: matchOnly),
                          items: targets, label: "参考图匹配")
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
