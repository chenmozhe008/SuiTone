import AppKit

extension WorkspaceStore {
    /// 一批算几张：首屏正好 6 格，后台补齐和「展开全部」也按这个粒度分批。
    static let styleTileBatch = 6

    /// 首屏只算看得见的 6 款：先问推荐，再按推荐顺序出图；剩下的过一会儿补。
    /// 之前一次算 34 款要 2 秒多，而首屏只显示 6 格，剩下的时间都是白等。
    func loadStyleTiles() {
        guard let photo=current, photo.ready else{return}
        // 这一组首屏已经有了就不重复算；换照片时 tiles 会被清空，自然会重来。
        let headline = styleHeadline(for: styleFamily)
        if styleGuideAssetID == photo.assetID, headline.allSatisfy({ styleTiles[$0] != nil }) { return }
        styleTileTask?.cancel()
        styleFillTask?.cancel()
        styleTileTask=Task {
            await fetchStyleGuide(photo)
            guard !Task.isCancelled else { return }
            await fetchStyleTiles(photo, ids: styleHeadline(for: styleFamily))
            guard !Task.isCancelled else { return }
            // 用户多半还会点「展开全部」；等预览和滑块先跑完，再悄悄把下一批备好。
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, current?.assetID == photo.assetID else { return }
            let next = styleOrder(for: styleFamily).map(\.id).filter { styleTiles[$0] == nil }
            await fetchStyleTiles(photo, ids: Array(next.prefix(Self.styleTileBatch)))
        }
    }

    /// 切换分组或展开全部时，把这一组还没算出来的补齐；每批 6 张，边算边显示。
    func ensureStyleTiles(for family: String) {
        guard let photo = current, photo.ready else { return }
        let missing = styleOrder(for: family).map(\.id).filter { styleTiles[$0] == nil }
        guard !missing.isEmpty else { return }
        styleFillTask?.cancel()
        styleFillTask = Task {
            var index = 0
            while index < missing.count {
                if Task.isCancelled { return }
                let batch = Array(missing[index..<min(index + Self.styleTileBatch, missing.count)])
                await fetchStyleTiles(photo, ids: batch)
                index += batch.count
            }
        }
    }

    private func fetchStyleGuide(_ photo: PhotoRecord) async {
        guard styleGuideAssetID != photo.assetID else { return }
        do {
            let guide: StyleGuide = try await engine.request("style-recommend", body: ["id": photo.assetID])
            guard !Task.isCancelled, current?.assetID == photo.assetID else { return }
            styleGuide = guide; styleGuideAssetID = photo.assetID
        } catch {
            // 推荐只是锦上添花；失败就按默认顺序，不打扰用户。
        }
    }

    private func fetchStyleTiles(_ photo: PhotoRecord, ids: [String]) async {
        let missing = ids.filter { styleTiles[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            struct Tiles: Decodable { var tiles: [String: String] }
            let result: Tiles = try await engine.request("style-tiles", body: ["id": photo.assetID, "ids": missing])
            guard !Task.isCancelled, current?.assetID == photo.assetID else { return }
            styleTiles.merge(result.tiles) { _, new in new }
        } catch {
            if !Task.isCancelled { status = "风格缩略图未就绪，可直接点击试用" }
        }
    }

    /// 展示顺序：推荐的 6 款在前，其余沿用引擎原顺序，一款都不少。
    func styleOrder(for family: String) -> [StylePreset] {
        let group = styles.filter { $0.creative == (family == "creative") }
        guard let guide = currentStyleGuide else { return group }
        let byID = Dictionary(uniqueKeysWithValues: group.map { ($0.id, $0) })
        let head = guide.ids(family).compactMap { byID[$0] }
        guard !head.isEmpty else { return group }
        let picked = Set(head.map(\.id))
        return head + group.filter { !picked.contains($0.id) }
    }

    /// 首屏那几款，缩略图也先只算这些。
    func styleHeadline(for family: String) -> [String] {
        styleOrder(for: family).prefix(Self.styleTileBatch).map(\.id)
    }

    var currentStyleGuide: StyleGuide? {
        styleGuideAssetID == current?.assetID ? styleGuide : nil
    }

    func applyStyle(_ style: String) {
        runPhotoOperation(.style(style), items: targets,
            label: "应用\(styles.first(where: { $0.id == style })?.title ?? "风格")")
    }

    /// 一键复原：照片换回导入时的原图，调色、移除杂物、AI 生成版本、画质全部去掉；记成一步，可以撤销找回。
    func resetToOriginal() {
        finishEditing()
        let items = targets
        guard !items.isEmpty, !controlsBlocked else { return }
        let before = capture(items)
        clearRepairSelection(); localRegion = nil; overlay = ""; versionPreview = nil
        for i in photos.indices where items.contains(where: { $0.id == photos[i].id }) {
            photos[i].assetID = photos[i].imported.id
            photos[i].parameters = AdjustmentParameters()
            photos[i].operations = []
            photos[i].quality = QualitySettings()
            photos[i].lookName = "原图"; photos[i].notes = []
            photos[i].previewPath = nil
        }
        analysis = nil; styleTiles = [:]
        recordChange("复原原图", before: before)
        status = items.count > 1 ? "已复原 \(items.count) 张，可撤销" : "已复原，可撤销"
        schedulePreview(); refreshGrid(); loadStyleTiles()
    }

    func saveMyStyle() {
        finishEditing()
        guard let photo = current else { return }
        var params = photo.parameters
        params.rotation = 0; params.angle = 0; params.rotationExpanded = false; params.flip = ""; params.crop = nil
        params.regions = [:]  // 参考图反推的区域目标色属于原照片，不随风格带走
        params.manualMasks = [:]
        params.local = params.local.filter { !$0.key.hasPrefix("selection-") }
        let name = "我的风格 \(myStyles.count + 1)"
        myStyles.append(MyStyle(name: name, parameters: params))
        status = "已存为\(name)"
    }

    func applyMyStyle(_ style: MyStyle) {
        runPhotoOperation(.personalStyle(style.parameters, name: style.name),
                          items: targets, label: "应用" + style.name)
    }

    /// 「自动」：取智能自然的建议值，只覆盖这一组（光线或颜色）的细项。
    func autoAdjust(_ group: String) {
        guard let photo = current, photo.ready else { return }
        Task {
            do {
                let result: SmartResponse = try await engine.request("smart", body: ["id": photo.assetID, "style": "smart",
                    "quality": try EngineClient.object(photo.quality)])
                guard current?.id == photo.id, current?.parameters == photo.parameters else { return }
                let s = result.params
                change(group == "light" ? "自动光线" : "自动颜色") {
                    if group == "light" {
                        $0.exposure = s.exposure; $0.contrast = s.contrast; $0.highlights = s.highlights
                        $0.shadows = s.shadows; $0.blackWhite = s.blackWhite; $0.whites = 0; $0.blacks = 0; $0.light = 0
                    } else {
                        $0.saturation = s.saturation; $0.temperature = s.temperature; $0.tint = s.tint; $0.vibrance = 0
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 在照片上点一下，选中所在区域；没有把握时不选。
    func pickRegion(x: Double, y: Double) {
        guard let photo = current else { return }
        Task {
            do {
                struct Picked: Decodable { var region: String }
                let result: Picked = try await engine.request("region-at", body: ["id": photo.assetID, "x": x, "y": y])
                guard current?.id == photo.id else { return }
                if result.region.isEmpty { status = "这里没有可单独调整的区域" }
                else { selectLocalRegion(result.region) }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 选中局部区域：照片上常驻一圈细轮廓（不遮挡颜色），整片染色只在点「显示选区」时出现。
    func selectLocalRegion(_ region: String?) {
        localRegion = region; localOutline = nil
        showLocalOverlay(nil)
        if region != nil && analysis == nil { loadAnalysis() }
        guard let region, let photo = current else { return }
        Task {
            struct Outline: Decodable { var outline: String }
            do {
                let result: Outline = try await engine.request("region-outline", body: ["id": photo.assetID,
                    "params": try EngineClient.object(photo.parameters), "name": region])
                if current?.id == photo.id && localRegion == region { localOutline = result.outline }
            } catch {
                if current?.id == photo.id && localRegion == region { status = "选区轮廓暂不可用，可点「显示选区」查看" }
            }
        }
    }

    func showLocalOverlay(_ region: String?) {
        overlayPreviewTask?.cancel(); overlayPreviewTask = nil
        overlay = region ?? ""; manualOverlay = nil
        guard let region, region.hasPrefix("selection-"), let photo = current else { return }
        Task {
            do {
                struct Result: Decodable { var overlay: String }
                let result: Result = try await engine.request("manual-mask-overlay", body: ["id": photo.assetID,
                    "params": try EngineClient.object(photo.parameters), "name": region])
                guard current?.assetID == photo.assetID, current?.parameters == photo.parameters, overlay == region else { return }
                manualOverlay = result.overlay
            } catch { if overlay == region { self.error = error.localizedDescription } }
        }
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
