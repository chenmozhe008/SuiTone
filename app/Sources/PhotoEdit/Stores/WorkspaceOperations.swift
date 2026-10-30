import Foundation

/// One photo operation, shared by controls and AI. Preparation never mutates the workspace.
enum PhotoOperation {
    case parameters(AdjustmentParameters, name: String, notes: [String])
    case style(String)
    case suggestion(String)
    case quality(denoise: Bool?, scale: Int?)
    case match(references: [String], scopes: [String: String], only: String)
    case repair(RemovalOperation)
    /// 把 AI 生成的图片作为照片的新版本（之后照样能调色、撤销、导出）
    case generated(path: String)
}

extension WorkspaceStore {
    func prepareParameters(_ params: AdjustmentParameters, name: String, notes: [String], on photo: PhotoRecord) -> PhotoRecord {
        var prepared = photo
        prepared.parameters = params; prepared.lookName = name; prepared.notes = notes; prepared.previewPath = nil
        return prepared
    }

    func prepareOperation(_ operation: PhotoOperation, on photo: PhotoRecord) async throws -> PhotoRecord {
        var prepared = photo
        switch operation {
        case let .parameters(params, name, notes):
            prepared = prepareParameters(params, name: name, notes: notes, on: photo)
        case let .style(style):
            let result: SmartResponse = try await engine.request("smart", body: ["id": photo.assetID,
                "style": style, "quality": try EngineClient.object(photo.quality)])
            prepared.parameters = result.params; prepared.lookName = result.title
            prepared.notes = result.notes; prepared.previewPath = result.preview; prepared.ready = true
        case let .suggestion(cardID):
            let result: SmartResponse = try await engine.request("suggestion-apply", body: ["id": photo.assetID,
                "card_id": cardID, "params": try EngineClient.object(photo.parameters),
                "quality": try EngineClient.object(photo.quality)])
            prepared.parameters = result.params; prepared.lookName = result.title
            prepared.notes = result.notes; prepared.previewPath = result.preview; prepared.ready = true
        case let .quality(denoise, scale):
            if let denoise { prepared.quality.denoise = denoise }
            if let scale {
                guard [1, 2, 4].contains(scale) else { throw EngineError(message: "放大倍数无效") }
                prepared.quality.scale = scale
            }
            let result: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID,
                "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(prepared.quality)])
            prepared.previewPath = result.preview
        case let .match(references, scopes, only):
            guard !references.isEmpty else { throw EngineError(message: "请先添加参考图") }
            var body: [String: Any] = ["id": photo.assetID, "references": references,
                "params": try EngineClient.object(photo.parameters), "reference_scopes": scopes]
            if only != "all" { body["only"] = only }
            let result: MatchResponse = try await engine.request("match", body: body)
            guard !result.learned.isEmpty else {
                throw EngineError(message: result.notes.first ?? "参考图和照片没有可匹配的共同区域")
            }
            prepared.parameters = result.params
            prepared.lookName = result.learned.isEmpty ? photo.lookName : "参考匹配"
            prepared.notes = result.notes + result.learned.map { "已学习" + RegionNames.title($0) + "的颜色与影调" }
            let rendered: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID,
                "params": try EngineClient.object(prepared.parameters), "quality": try EngineClient.object(photo.quality)])
            prepared.previewPath = rendered.preview
        case let .repair(removal):
            var body = try EngineClient.object(removal); body["id"] = photo.assetID
            let result: RemoveResponse = try await engine.request("remove", body: body)
            let rendered: PreviewResponse = try await engine.request("preview", body: ["id": result.id,
                "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
            prepared.assetID = result.id; prepared.operations.append(removal); prepared.previewPath = rendered.preview
        case let .generated(path):
            struct Adopted: Decodable { var id: String; var stored: String }
            let result: Adopted = try await engine.request("adopt-generated", body: ["id": photo.assetID, "path": path])
            let rendered: PreviewResponse = try await engine.request("preview", body: ["id": result.id,
                "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
            prepared.assetID = result.id
            prepared.operations.append(RemovalOperation(box: [0, 0, 1, 1], generated: result.stored))
            prepared.previewPath = rendered.preview
            prepared.notes = ["已换成 AI 生成版本，调色参数继续作用于新图"]
        }
        try Task.checkCancellation()
        return prepared
    }

    /// Commit only when the entire photo still matches the state used to prepare the result.
    @discardableResult func commitPrepared(_ prepared: PhotoRecord, expected: EditSnapshot) -> Bool {
        guard let i = photos.firstIndex(where: { $0.id == prepared.id }), photos[i].snapshot == expected else { return false }
        if currentID == prepared.id && photos[i].assetID != prepared.assetID {
            analysis = nil; overlay = ""; styleTiles = [:]; selectionBox = nil; repairMaskOverlay = nil
        }
        photos[i].assetID = prepared.assetID; photos[i].parameters = prepared.parameters
        photos[i].operations = prepared.operations; photos[i].quality = prepared.quality
        photos[i].lookName = prepared.lookName; photos[i].notes = prepared.notes
        photos[i].previewPath = prepared.previewPath; photos[i].ready = prepared.ready
        return true
    }

    func runPhotoOperation(_ operation: PhotoOperation, items: [PhotoRecord], label: String) {
        guard !controlsBlocked, !items.isEmpty else { return }
        finishEditing()
        batchWorking = true; progressDone = 0; progressTotal = items.count; showOriginal = false
        batchTask = Task {
            var before: [String: EditSnapshot] = [:]
            defer {
                let changeID = recordChange(label, before: before)
                if case .suggestion = operation, let changeID {
                    let changed = items.filter { before[$0.id] != nil }
                    let notes = changed.flatMap { original in
                        guard let photo = photos.first(where: { $0.id == original.id }) else { return [String]() }
                        return changed.count > 1 ? photo.notes.map { photo.imported.name + "：" + $0 } : photo.notes
                    }
                    chatMessages.append(ChatMessage(role: "assistant", text: "已应用：" + label,
                        notes: notes, affectedPhotos: changed.map(\.imported.name), changeID: changeID))
                }
                batchWorking = false; batchTask = nil
            }
            var skipped = 0, unavailable = 0, processed = 0
            for photo in items {
                if Task.isCancelled { status = "已停止，已完成的调整可以撤销"; return }
                defer { processed += 1 }
                do {
                    status = "\(label) \(processed + 1)/\(progressTotal)"
                    let result = try await prepareOperation(operation, on: photo)
                    if commitPrepared(result, expected: photo.snapshot) {
                        before[photo.id] = photo.snapshot; progressDone += 1
                    } else { skipped += 1 }
                } catch {
                    if Task.isCancelled { status = "已停止，已完成的调整可以撤销" }
                    else if case .suggestion = operation, error.localizedDescription == "这张照片没有可用的此项建议" {
                        unavailable += 1; continue
                    }
                    else { self.error = error.localizedDescription }
                    return
                }
            }
            status = "\(label)完成 · \(progressDone) 张" + (skipped > 0 ? " · \(skipped) 张已改变，跳过" : "")
                + (unavailable > 0 ? " · \(unavailable) 张不适用，跳过" : "")
        }
    }
}
