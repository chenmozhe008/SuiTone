import Foundation

extension WorkspaceStore {
    var validRepairSelection: Bool {
        guard let box = selectionBox, box.count == 4,
              box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        return box[2] - box[0] > 0.002 && box[3] - box[1] > 0.002
    }

    func removalOperation(_ box: [Double]) -> RemovalOperation {
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

    func finishRepairTransition(to tab: String) {
        let keepSelection = tab == "chat" && repairDraft == nil
        let savedBox = selectionBox, savedStrokes = repairStrokes, savedPolygon = repairPolygon, savedPoint = repairPoint
        cancelRepairPreview()
        if keepSelection {
            selectionBox = savedBox; repairStrokes = savedStrokes
            repairPolygon = savedPolygon; repairPoint = savedPoint
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
