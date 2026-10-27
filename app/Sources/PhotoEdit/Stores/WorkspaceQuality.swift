import Foundation

extension WorkspaceStore {
    func applyQuality(denoise: Bool? = nil, scale: Int? = nil) {
        guard !controlsBlocked, scale == nil || [1, 2, 4].contains(scale!) else { return }
        finishEditing()
        let items = targets.filter { (denoise != nil && $0.quality.denoise != denoise!) || (scale != nil && $0.quality.scale != scale!) }
        guard !items.isEmpty else { return }
        let before = capture(items)
        batchWorking = true; progressDone = 0; progressTotal = items.count; showOriginal = false
        batchTask = Task {
            defer {
                recordChange("调整画质", before: before)
                batchWorking = false; batchTask = nil
            }
            for photo in items {
                if Task.isCancelled { status = "已停止，已完成的画质调整可以撤销"; return }
                do {
                    var quality = photo.quality
                    if let denoise { quality.denoise = denoise }
                    if let scale { quality.scale = scale }
                    status = "生成画质预览 \(progressDone + 1)/\(progressTotal)"
                    let response: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID,
                        "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(quality)])
                    guard !Task.isCancelled else { status = "已停止，未应用本次画质结果"; return }
                    guard let i = photos.firstIndex(where: { $0.id == photo.id }),
                          photos[i].snapshot == photo.snapshot else { continue }
                    photos[i].quality = quality; photos[i].previewPath = response.preview
                    progressDone += 1
                } catch {
                    if Task.isCancelled { status = "已停止，已完成的画质调整可以撤销" }
                    else { self.error = error.localizedDescription }
                    return
                }
            }
            status = "画质调整完成 · \(progressDone) 张，可撤销"
        }
    }
}
