import AppKit

extension WorkspaceStore {
    var topazPhotoURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.topazlabs.TopazPhoto")
    }

    func openInTopazPhoto() {
        guard !controlsBlocked, let photo = current, let application = topazPhotoURL else { return }
        busy = true
        status = "正在准备照片并打开 Topaz Photo…"
        Task {
            do {
                struct Rendered: Decodable { var path: String }
                let rendered: Rendered = try await engine.request("render-full", body: ["id": photo.assetID,
                    "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SuiTone/Topaz 输入", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = URL(fileURLWithPath: photo.imported.name).deletingPathExtension().lastPathComponent
                let destination = folder.appendingPathComponent(name + "-" + UUID().uuidString + ".png")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: rendered.path), to: destination)
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([destination], withApplicationAt: application, configuration: configuration) { _, error in
                    Task { @MainActor in
                        self.busy = false
                        if let error {
                            self.error = "无法打开 Topaz Photo：" + error.localizedDescription
                            self.status = "打开 Topaz Photo 未完成"
                        } else {
                            self.status = "已送至 Topaz Photo；完成后导出，再导入结果"
                        }
                    }
                }
            } catch {
                busy = false
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
