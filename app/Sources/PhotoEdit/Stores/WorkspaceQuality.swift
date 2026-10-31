import AppKit

extension WorkspaceStore {
    var topazPhotoURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.topazlabs.TopazPhoto")
    }

    func openInTopazPhoto() {
        guard !controlsBlocked, topazTask == nil, let photo = current, let application = topazPhotoURL else { return }
        status = "正在准备照片送到 Topaz Photo…"
        topazTask = Task {
            defer { topazTask = nil }
            do {
                struct Rendered: Decodable { var path: String }
                let pristine = photo.parameters == AdjustmentParameters() && photo.operations.isEmpty
                let source: URL
                if pristine {
                    source = URL(fileURLWithPath: photo.imported.path)
                } else {
                    let rendered: Rendered = try await engine.request("render-full", body: ["id": photo.assetID,
                        "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(QualitySettings())])
                    source = URL(fileURLWithPath: rendered.path)
                }
                try Task.checkCancellation()
                let destination = try await Task.detached(priority: .userInitiated) {
                    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("SuiTone/Topaz 输入", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
                    let destination = folder.appendingPathComponent(UUID().uuidString + "." + ext)
                    try FileManager.default.copyItem(at: source, to: destination)
                    return destination
                }.value
                try Task.checkCancellation()
                let configuration = NSWorkspace.OpenConfiguration()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open([destination], withApplicationAt: application, configuration: configuration) { _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                status = "已送至 Topaz Photo；完成后导出，再导入结果"
            } catch is CancellationError {
                status = "已取消准备 Topaz 图片"
            } catch {
                self.error = error.localizedDescription
                status = "准备 Topaz Photo 输入图片失败"
            }
        }
    }

    func applyQuality(denoise: Bool? = nil, scale: Int? = nil) {
        guard !controlsBlocked, scale == nil || [1, 2, 4].contains(scale!) else { return }
        let items = targets.filter { (denoise != nil && $0.quality.denoise != denoise!) || (scale != nil && $0.quality.scale != scale!) }
        runPhotoOperation(.quality(denoise: denoise, scale: scale), items: items, label: "调整画质")
    }
}
