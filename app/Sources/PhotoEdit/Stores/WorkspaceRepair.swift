import Foundation

extension WorkspaceStore {
    var validRepairSelection: Bool {
        guard let box = selectionBox, box.count == 4,
              box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        return box[2] - box[0] > 0.002 && box[3] - box[1] > 0.002
    }

    private func removalOperation(_ box: [Double]) -> RemovalOperation {
        RemovalOperation(box: box,
            classes: repairMode == "classes" ? repairClasses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil,
            keep: repairMode == "keepSky" ? ["sky"] : nil)
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
                var body = try EngineClient.object(operation); body["id"] = photo.assetID
                let result: RemoveResponse = try await engine.request("remove", body: body)
                let rendered: PreviewResponse = try await engine.request("preview", body: ["id": result.id, "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
                guard repairRevision == revision, currentID == photo.id, current?.assetID == photo.assetID,
                      current?.parameters == photo.parameters, inspectorTab == "repair" else { return }
                repairDraft = RepairDraft(photoID: photo.id, sourceAssetID: photo.assetID, parameters: photo.parameters,
                    operation: operation, resultAssetID: result.id,
                    beforePath: photo.previewPath ?? photo.imported.original, previewPath: rendered.preview)
                repairShowingBefore = false
                status = "修复预览已生成"
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancelRepairPreview() {
        let hadDraft = repairDraft != nil
        repairRevision += 1
        repairDraft = nil; repairShowingBefore = false; repairMaskOverlay = nil; selectionBox = nil
        if hadDraft { status = "已取消本次修复" }
    }

    func applyRepairPreview() {
        guard let draft = repairDraft, let i = currentIndex,
              photos[i].id == draft.photoID, photos[i].assetID == draft.sourceAssetID,
              photos[i].parameters == draft.parameters else {
            cancelRepairPreview(); return
        }
        let before = photos[i].snapshot
        photos[i].assetID = draft.resultAssetID
        photos[i].operations.append(draft.operation)
        photos[i].previewPath = draft.previewPath
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
                if currentID == photo.id { repairMaskOverlay = result.overlay; status = "红色为去除选区" }
            } catch { self.error = error.localizedDescription }
        }
    }
}
