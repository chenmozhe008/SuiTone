import AppKit

extension WorkspaceStore {
    var validRepairSelection: Bool {
        guard let box = selectionBox, box.count == 4,
              box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        return box[2] - box[0] > 0.002 && box[3] - box[1] > 0.002
    }

    func removalOperation(_ box: [Double]) -> RemovalOperation {
        if !selectionParts.isEmpty {
            // 只有一个方框时保留「保留天空、指定对象」这些方框专属选项
            if selectionParts.count == 1, let only = selectionParts.first, let frame = only.box, repairMode != "box" {
                return RemovalOperation(box: frame,
                    classes: repairMode == "classes" ? repairClasses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil,
                    keep: repairMode == "keepSky" ? ["sky"] : nil)
            }
            return RemovalOperation(box: box, parts: selectionParts)
        }
        switch repairTool {
        case "brush" where !repairStrokes.isEmpty:
            return RemovalOperation(box: box, strokes: repairStrokes, radius: brushSize)
        case "lasso" where repairPolygon.count >= 3:
            return RemovalOperation(box: box, polygon: repairPolygon)
        case "object" where repairPoint != nil:
            return RemovalOperation(box: box, point: repairPoint)
        default:
            return RemovalOperation(box: box,
                classes: repairMode == "classes" ? repairClasses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil,
                keep: repairMode == "keepSky" ? ["sky"] : nil)
        }
    }

    /// 画笔、套索、点选画完后，用外接框作为选区范围（AI 修复和旧记录仍按框识别）。
    func updateRepairBounds() {
        repairMaskOverlay = nil
        var points: [[Double]] = []; var margin = 0.0
        switch repairTool {
        case "brush": points = repairStrokes.flatMap { $0 }; margin = brushSize
        case "lasso": points = repairPolygon
        case "object": selectionBox = repairPoint == nil ? nil : [0, 0, 1, 1]; return
        default: return
        }
        guard let first = points.first else { selectionBox = nil; return }
        var box = [first[0], first[1], first[0], first[1]]
        for p in points { box = [min(box[0], p[0]), min(box[1], p[1]), max(box[2], p[0]), max(box[3], p[1])] }
        let photoRatio = current.map { Double($0.imported.width) / Double(max($0.imported.height, 1)) } ?? 1
        selectionBox = [max(0, box[0] - margin), max(0, box[1] - margin * photoRatio),
                        min(1, box[2] + margin), min(1, box[3] + margin * photoRatio)]
    }

    func clearRepairSelection() {
        selectionBox = nil; repairMaskOverlay = nil
        repairStrokes = []; repairPolygon = []; repairPoint = nil
        selectionParts = []; selectionDraftBox = nil; selectionOverlay = nil; editingSelectionKey = nil
        selectionRevision += 1
    }

    /// 选区、移除、AI 改图三页用多笔选区；抠图仍是点哪个主体抠哪个。
    var usesSelectionParts: Bool { ["selection", "repair", "aiedit"].contains(inspectorTab) }

    /// 松手时把正在画的这一笔记进选区：工具条选「减去」或按住 ⌥ 时为减。
    func commitSelectionPart() {
        let subtract = selectionSubtract || NSEvent.modifierFlags.contains(.option)
        var part: SelectionPart?
        switch repairTool {
        case "brush": if let stroke = repairStrokes.last, !stroke.isEmpty { part = SelectionPart(strokes: [stroke], radius: brushSize) }
        case "lasso": if repairPolygon.count >= 3 { part = SelectionPart(polygon: repairPolygon) }
        case "object": if let point = repairPoint { part = SelectionPart(point: point) }
        default:
            if let b = selectionDraftBox, b[2] - b[0] > 0.004, b[3] - b[1] > 0.004 { part = SelectionPart(box: b) }
        }
        repairStrokes = []; repairPolygon = []; repairPoint = nil; selectionDraftBox = nil
        guard var part else { return }
        if subtract && !selectionParts.contains(where: { !$0.subtract }) { status = "先添加一块选区，再用减去"; return }
        part.subtract = subtract
        selectionParts.append(part)
        refreshSelection()
    }

    func undoSelectionPart() {
        guard !selectionParts.isEmpty else { return }
        selectionParts.removeLast(); refreshSelection()
    }

    /// 外接框给 AI 和旧逻辑用；再请引擎合成真实的选区样子（含减去的部分）。
    func refreshSelection() {
        repairMaskOverlay = nil; selectionOverlay = nil; selectionRevision += 1
        let adds = selectionParts.filter { !$0.subtract }
        guard !adds.isEmpty, let photo = current else { selectionBox = nil; return }
        var box = [1.0, 1.0, 0.0, 0.0]
        func include(_ x: Double, _ y: Double, _ margin: Double = 0) {
            box = [min(box[0], x - margin), min(box[1], y - margin), max(box[2], x + margin), max(box[3], y + margin)]
        }
        for part in adds {
            if part.point != nil { box = [0, 0, 1, 1]; break }
            if let b = part.box { include(b[0], b[1]); include(b[2], b[3]) }
            for p in part.polygon ?? [] { include(p[0], p[1]) }
            for p in part.strokes?.flatMap({ $0 }) ?? [] { include(p[0], p[1], part.radius ?? brushSize) }
        }
        selectionBox = [max(0, box[0]), max(0, box[1]), min(1, box[2]), min(1, box[3])]
        let revision = selectionRevision, parts = selectionParts
        Task {
            struct Overlay: Decodable { var overlay: String; var coverage: Double }
            do {
                let body: [String: Any] = ["id": photo.assetID, "selection": ["parts": try parts.map { try EngineClient.object($0) }]]
                let result: Overlay = try await engine.request("selection-overlay", body: body)
                guard revision == selectionRevision, current?.id == photo.id else { return }
                selectionOverlay = result.overlay
                if result.coverage < 0.0005 { status = "减去之后选区是空的" }
            } catch { if revision == selectionRevision { self.error = error.localizedDescription } }
        }
    }

    /// 把当前选区存成（或更新）局部调整用的手动选区，并切到调整页单独调它。
    func useSelectionForLocal() {
        guard !selectionParts.isEmpty, let box = selectionBox, current != nil, !controlsBlocked else { return }
        let operation = RemovalOperation(box: box, parts: selectionParts)
        let key: String
        if let editing = editingSelectionKey, current?.parameters.manualMasks[editing] != nil {
            key = editing
            change("编辑选区") { $0.manualMasks[key] = operation }
        } else {
            guard (current?.parameters.manualMasks.count ?? 0) < 32 else { status = "最多保存 32 个选区"; return }
            key = "selection-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
            change("创建局部选区") { $0.manualMasks[key] = operation }
        }
        inspectorTab = "adjust"
        Task { @MainActor in await Task.yield(); self.selectLocalRegion(key) }
    }

    /// 打开已保存的手动选区继续加减；旧的单笔选区转成一笔。
    func editSavedSelection(_ key: String) {
        guard let saved = current?.parameters.manualMasks[key] else { return }
        let parts = saved.parts ?? [SelectionPart(box: saved.strokes == nil && saved.polygon == nil && saved.point == nil ? saved.box : nil,
                                                  strokes: saved.strokes, radius: saved.radius, polygon: saved.polygon, point: saved.point)]
        inspectorTab = "selection"
        Task { @MainActor in
            await Task.yield()
            self.selectionParts = parts; self.editingSelectionKey = key; self.refreshSelection()
        }
    }

    /// 对话页画框时，从一份全新的方框选区开始，不沿用修复页的旧选法。
    func beginChatSelection() {
        clearRepairSelection()
        repairTool = "box"; repairMode = "box"
    }

    func updateChatSelection(from start: [Double], to end: [Double]) {
        guard start.count == 2, end.count == 2,
              (start + end).allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        selectionBox = [min(start[0], end[0]), min(start[1], end[1]),
                        max(start[0], end[0]), max(start[1], end[1])]
    }

    func editSelectedRegion() {
        guard validRepairSelection, let box = selectionBox, current != nil, !controlsBlocked else { return }
        guard (current?.parameters.manualMasks.count ?? 0) < 32 else { status = "最多保存 32 个选区"; return }
        var selection = removalOperation(box)
        selection.classes = nil; selection.keep = nil
        let key = "selection-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        change("创建局部选区") { $0.manualMasks[String(key)] = selection }
        inspectorTab = "adjust"
        Task { @MainActor in
            await Task.yield()
            self.selectLocalRegion(String(key))
        }
    }

    func finishRepairTransition(to tab: String) {
        // 选区跟着人走：在对话、选区、移除、AI 改图之间切换都保留，只有抠图（单独点选）和换照片会清掉。
        let keepSelection = ["chat", "repair", "selection", "aiedit", "adjust"].contains(tab) && repairDraft == nil
        let savedBox = selectionBox, savedStrokes = repairStrokes, savedPolygon = repairPolygon, savedPoint = repairPoint
        let savedParts = selectionParts, savedOverlay = selectionOverlay, savedKey = editingSelectionKey
        cancelRepairPreview()
        if keepSelection {
            selectionBox = savedBox; repairStrokes = savedStrokes
            repairPolygon = savedPolygon; repairPoint = savedPoint
            selectionParts = savedParts; selectionOverlay = savedOverlay; editingSelectionKey = savedKey
        }
    }

    func remove() {
        guard let photo = current, let box = selectionBox, !controlsBlocked, validRepairSelection else { return }
        finishEditing()
        let operation = removalOperation(box)
        let revision = repairRevision
        busy = true; repairMaskOverlay = nil; showOriginal = false
        status = "正在生成修复预览…"
        Task {
            defer { busy = false }
            do {
                let prepared = try await prepareOperation(.repair(operation), on: photo)
                guard repairRevision == revision, currentID == photo.id, current?.assetID == photo.assetID,
                      current?.parameters == photo.parameters, inspectorTab == "repair" else { return }
                repairDraft = RepairDraft(photoID: photo.id, sourceAssetID: photo.assetID, parameters: photo.parameters,
                    operation: operation, resultAssetID: prepared.assetID,
                    beforePath: photo.previewPath ?? photo.imported.original, previewPath: prepared.previewPath!)
                repairShowingBefore = false
                status = "修复预览已生成"
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancelRepairPreview() {
        let hadDraft = repairDraft != nil
        repairRevision += 1
        repairDraft = nil; repairShowingBefore = false
        clearRepairSelection()
        if hadDraft { status = "已取消本次修复" }
    }

    func applyRepairPreview() {
        guard let draft = repairDraft, let i = currentIndex,
              photos[i].id == draft.photoID, photos[i].assetID == draft.sourceAssetID,
              photos[i].parameters == draft.parameters else {
            cancelRepairPreview(); return
        }
        let before = photos[i].snapshot
        var prepared = photos[i]
        prepared.assetID = draft.resultAssetID; prepared.operations.append(draft.operation)
        prepared.previewPath = draft.previewPath
        guard commitPrepared(prepared, expected: before) else { cancelRepairPreview(); return }
        recordChange("移除杂物", before: [draft.photoID: before])
        cancelRepairPreview()
        analysis = nil; overlay = ""; styleTiles = [:]
        status = "已保留修复 · 可撤销"
    }

    func previewRepairMask() {
        guard let photo = current, let box = selectionBox, !controlsBlocked, validRepairSelection else { return }
        let operation = removalOperation(box)
        busy = true
        Task {
            defer { busy = false }
            do {
                struct Mask: Decodable { var overlay: String; var pixels: Int }
                var body = try EngineClient.object(operation); body["id"] = photo.assetID
                let result: Mask = try await engine.request("repair-mask", body: body)
                if currentID == photo.id { repairMaskOverlay = result.overlay; status = "红色是将要去除的部分" }
            } catch { self.error = error.localizedDescription }
        }
    }
}
