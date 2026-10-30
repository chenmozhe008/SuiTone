import AppKit

extension WorkspaceStore {
    func previewCutout() {
        guard let photo = current, let point = repairPoint, !busy else { return }
        cutoutPreview = nil; cutoutSnapshot = nil; busy = true
        Task {
            defer { busy = false }
            do {
                struct Result: Decodable { var preview: String }
                let result: Result = try await engine.request("cutout", body: ["id": photo.assetID, "point": point,
                    "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
                guard currentID == photo.id, current?.snapshot == photo.snapshot, repairPoint == point, inspectorTab == "cutout" else { return }
                cutoutPreview = result.preview; cutoutSnapshot = photo.snapshot
                status = "抠图预览已生成，请检查边缘"
            } catch { self.error = error.localizedDescription }
        }
    }

    func saveCutout() {
        guard let photo = current, let point = repairPoint, cutoutPreview != nil,
              cutoutSnapshot == photo.snapshot, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = URL(fileURLWithPath: photo.imported.name).deletingPathExtension().lastPathComponent + "-抠图.png"
        panel.message = "保存透明 PNG，不覆盖已有文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "正在保存透明 PNG…"
        Task {
            defer { busy = false }
            do {
                struct Result: Decodable { var path: String }
                let result: Result = try await engine.request("cutout", body: ["id": photo.assetID, "point": point,
                    "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality),
                    "destination": url.path])
                status = "已保存透明 PNG：" + URL(fileURLWithPath: result.path).lastPathComponent
            } catch { self.error = error.localizedDescription }
        }
    }
}
