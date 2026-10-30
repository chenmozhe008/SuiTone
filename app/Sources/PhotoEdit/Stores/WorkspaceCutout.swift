import AppKit

extension WorkspaceStore {
    func resetCutout() {
        cutoutPreview = nil; cutoutSnapshot = nil; repairPoint = nil; selectionBox = nil
        status = "点击照片中要保留的主体"
    }

    /// 在调好色的预览图上做系统主体抠图，生成透明预览。
    func previewCutout() {
        guard let photo = current, let point = repairPoint, !busy else { return }
        let source = URL(fileURLWithPath: photo.previewPath ?? photo.imported.original)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("SuiTone-cutout-\(UUID().uuidString).png")
        cutoutPreview = nil; cutoutSnapshot = nil; busy = true; status = "正在识别主体…"
        Task {
            defer { busy = false }
            do {
                let coverage = try await Task.detached(priority: .userInitiated) {
                    try SubjectCutout.cutout(image: source, point: CGPoint(x: point[0], y: point[1]), output: output)
                }.value
                guard currentID == photo.id, current?.snapshot == photo.snapshot, repairPoint == point, inspectorTab == "cutout" else { return }
                cutoutPreview = output.path; cutoutSnapshot = photo.snapshot
                status = String(format: "已抠出主体，约占画面 %.0f%%，请检查边缘", coverage * 100)
            } catch { self.error = error.localizedDescription; status = "抠图未完成" }
        }
    }

    /// 先按原尺寸渲染调色、修复后的成品，再在全尺寸图上抠图，发丝边缘不因放大变糊。
    func saveCutout() {
        guard let photo = current, let point = repairPoint, cutoutPreview != nil,
              cutoutSnapshot == photo.snapshot, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = URL(fileURLWithPath: photo.imported.name).deletingPathExtension().lastPathComponent + "-抠图.png"
        panel.message = "保存为新的透明 PNG，原照片不变"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "正在按原尺寸生成透明 PNG…"
        Task {
            defer { busy = false }
            do {
                struct Rendered: Decodable { var path: String }
                let rendered: Rendered = try await engine.request("render-full", body: ["id": photo.assetID,
                    "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
                let source = URL(fileURLWithPath: rendered.path)
                try await Task.detached(priority: .userInitiated) {
                    _ = try SubjectCutout.cutout(image: source, point: CGPoint(x: point[0], y: point[1]), output: url)
                }.value
                try? FileManager.default.removeItem(at: source)
                status = "已保存透明 PNG：" + url.lastPathComponent
            } catch { self.error = error.localizedDescription; status = "保存未完成" }
        }
    }
}
