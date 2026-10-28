import Foundation

extension WorkspaceStore {
    func loadSuggestions(for assetID: String) async {
        suggestions = []
        do {
            let response: SuggestionsResponse = try await engine.request("suggestions", body: ["id": assetID])
            guard !Task.isCancelled, current?.assetID == assetID else { return }
            suggestions = response.cards
        } catch {
            guard !Task.isCancelled, current?.assetID == assetID else { return }
            status = "建议暂不可用，可继续手动调整"
        }
    }

    func applySuggestion(_ card: SuggestionCard) {
        guard let photo = current, !photo.excluded else { return }
        runPhotoOperation(.suggestion(card.id), items: [photo], label: card.title)
    }

    func sendChat() {
        let message = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !chatting, !controlsBlocked, !targets.isEmpty else { return }
        guard assistantProvider != "anthropic" || !anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        finishEditing()
        let items = targets
        let undoCandidate = undoChanges.last
        let undoAvailable = undoCandidate.map { Set($0.before.keys).isSubset(of: Set(items.map(\.id))) } ?? false
        let referenceIDs = references.map(\.id), scopes = referenceScopes, only = matchOnly
        let provider = assistantProvider, sendImages = visionEnabled, apiKey = anthropicAPIKey
        let repair: (id: String, operation: RemovalOperation)? = {
            guard validRepairSelection, let photo = current, let box = selectionBox,
                  items.contains(where: { $0.id == photo.id }) else { return nil }
            return (photo.assetID, removalOperation(box))
        }()
        let history = chatMessages.suffix(12).map { ["role": $0.role, "text": $0.text] }
        chatMessages.append(ChatMessage(role: "user", text: message))
        chatDraft = ""; chatting = true; assistantCancellationRequested = false; assistantPhase = "准备图片分析摘要"
        assistantTask = Task {
            defer { chatting = false; assistantJobID = nil; assistantTask = nil; assistantApplying = false; assistantPhase = "" }
            do {
                var body: [String: Any] = ["provider": provider, "message": message, "history": history,
                    "targets": try items.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters),
                                                 "quality": try EngineClient.object($0.quality)] },
                    "reference_ids": referenceIDs, "undo_available": undoAvailable, "image_consent": sendImages]
                if let repair { body["repair_selection"] = ["id": repair.id, "box": repair.operation.box] }
                if provider == "anthropic" { body["api_key"] = apiKey }
                struct Started: Decodable { var id: String }
                let started: Started = try await engine.request("assistant", body: body)
                assistantJobID = started.id
                if assistantCancellationRequested { await cancelAssistantJob(started.id) }
                while !Task.isCancelled {
                    let result: AssistantJob = try await engine.get("assistant-status", query: [URLQueryItem(name: "id", value: started.id)])
                    if assistantCancellationRequested {
                        chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。"))
                        return
                    }
                    if result.state == "done" {
                        assistantApplying = true; assistantPhase = "正在应用调整"
                        let review: (([PhotoRecord]) async throws -> [AssistantChange])? = sendImages ? { prepared in
                            try await self.reviewAssistantChanges(prepared, provider: provider,
                                originalRequest: message, referenceIDs: referenceIDs, apiKey: apiKey)
                        } : nil
                        await applyAssistantResult(result, items: items,
                            referenceIDs: referenceIDs, scopes: scopes, only: only, repair: repair,
                            undoCandidate: undoAvailable ? undoCandidate?.id : nil, review: review)
                        return
                    }
                    if result.state == "error" { throw EngineError(message: result.error ?? "AI 未完成请求") }
                    if result.state == "cancelled" { chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return }
                    assistantPhase = result.state == "preparing" ? "准备图片分析摘要" : "\(providers.first(where: { $0.id == assistantProvider })?.title ?? "AI") 正在思考"
                    try? await Task.sleep(for: .milliseconds(600))
                }
            } catch {
                let text = assistantCancellationRequested ? "已取消，本次没有应用调整。" : error.localizedDescription + "。本次设置未改变。"
                chatMessages.append(ChatMessage(role: "assistant", text: text))
            }
        }
    }

    func applyAssistantResult(_ result: AssistantJob, items: [PhotoRecord],
                              referenceIDs: [String] = [], scopes: [String: String] = [:], only: String = "all",
                              repair: (id: String, operation: RemovalOperation)? = nil, undoCandidate: UUID? = nil,
                              review: (([PhotoRecord]) async throws -> [AssistantChange])? = nil) async {
        guard !assistantCancellationRequested else { return }
        // 先结束正在拖动的滑块，让撤销目标与当前状态包含用户的最新手动编辑。
        if !(result.changes ?? []).isEmpty { finishEditing() }
        let requestedUndo = (result.changes ?? []).flatMap { $0.operations ?? [] }.contains { $0.kind == "undo" }
        if requestedUndo {
            guard let expected = undoCandidate, let current = undoChanges.last, current.id == expected,
                  Set(current.before.keys).isSubset(of: Set(items.map(\.id))) else {
                chatMessages.append(ChatMessage(role: "assistant", text: "撤销目标已改变或不在当前范围，本次没有操作。")); return
            }
            let count = current.before.count, label = current.label
            undo()
            chatMessages.append(ChatMessage(role: "assistant", text: "已撤销：\(label) · \(count) 张照片。"))
            return
        }
        var preparedResults: [(PhotoRecord, EditSnapshot, [String])] = []
        var appliedBefore: [String: EditSnapshot] = [:], details: [String] = [], affectedPhotos: [String] = []
        for change in result.changes ?? [] {
            guard let item = items.first(where: { $0.assetID == change.id }) else {
                details.append("未找到对应照片，已跳过"); continue
            }
            guard let i = photos.firstIndex(where: { $0.id == item.id }),
                  photos[i].assetID == item.assetID, photos[i].parameters == item.parameters else {
                details.append(item.imported.name + "：等待期间已改变，已跳过"); continue
            }
            let source = photos[i], origin = source.snapshot
            do {
                var prepared = source, notes = change.notes
                if change.params != source.parameters {
                    prepared = try await prepareOperation(.parameters(change.params, name: "AI 调整", notes: change.notes), on: prepared)
                }
                for operation in change.operations ?? [] {
                    let op: PhotoOperation
                    switch operation.kind {
                    case "denoise":
                        guard operation.value == 0 || operation.value == 1 else { throw EngineError(message: "降噪参数无效") }
                        let enabled = operation.value == 1
                        op = .quality(denoise: enabled, scale: nil)
                        if enabled != prepared.quality.denoise {
                            notes.append("降噪 \(prepared.quality.denoise ? "开启" : "关闭") → \(enabled ? "开启" : "关闭")")
                        }
                    case "upscale":
                        guard [1.0, 2.0, 4.0].contains(operation.value) else { throw EngineError(message: "放大倍数无效") }
                        let scale = Int(operation.value)
                        op = .quality(denoise: nil, scale: scale)
                        if scale != prepared.quality.scale {
                            let old = prepared.quality.scale == 1 ? "原尺寸" : "\(prepared.quality.scale) 倍"
                            let new = scale == 1 ? "原尺寸" : "\(scale) 倍"
                            notes.append("分辨率 \(old) → \(new)")
                        }
                    case "match":
                        guard !referenceIDs.isEmpty else { throw EngineError(message: "请先添加参考图") }
                        op = .match(references: referenceIDs, scopes: scopes, only: only); notes.append("匹配参考图")
                    case "repair":
                        guard let repair, repair.id == item.assetID else { throw EngineError(message: "请先框选要修复的区域") }
                        op = .repair(repair.operation); notes.append("修复所选区域")
                    default: throw EngineError(message: "AI 操作不在支持范围内")
                    }
                    prepared = try await prepareOperation(op, on: prepared)
                    if assistantCancellationRequested { break }
                }
                guard !assistantCancellationRequested, !Task.isCancelled else {
                    chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
                }
                if prepared.snapshot != origin { preparedResults.append((prepared, origin, notes)) }
                else { details.append(item.imported.name + "：没有需要更改的设置") }
            } catch {
                if assistantCancellationRequested || Task.isCancelled {
                    chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
                }
                details.append(item.imported.name + "：" + error.localizedDescription)
            }
        }
        if let review, !preparedResults.isEmpty {
            do {
                let changes = try await review(preparedResults.map { $0.0 })
                let ids = Set(preparedResults.map { $0.0.assetID })
                guard Set(changes.map(\.id)).count == changes.count,
                      changes.allSatisfy({ ids.contains($0.id) && ($0.operations ?? []).isEmpty }) else {
                    throw EngineError(message: "复看结果不在允许的范围")
                }
                for change in changes {
                    guard let index = preparedResults.firstIndex(where: { $0.0.assetID == change.id }) else { continue }
                    let (photo, origin, notes) = preparedResults[index]
                    if change.params != photo.parameters {
                        guard try reviewKeepsRequestedParameters(original: origin.parameters,
                                                                 first: photo.parameters, reviewed: change.params) else {
                            details.append(photo.imported.name + "：复看涉及未请求的参数，已跳过复看调整")
                            continue
                        }
                        let updated = try await prepareOperation(.parameters(change.params, name: "AI 调整", notes: notes + change.notes), on: photo)
                        preparedResults[index] = (updated, origin, notes + change.notes)
                    }
                }
            } catch {
                if assistantCancellationRequested || Task.isCancelled {
                    chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
                }
                details.append("复看未完成，保留首轮调整：" + error.localizedDescription)
            }
        }
        guard !assistantCancellationRequested, !Task.isCancelled else {
            chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
        }
        for (prepared, origin, notes) in preparedResults {
            guard commitPrepared(prepared, expected: origin) else {
                details.append(prepared.imported.name + "：等待期间已改变，已跳过"); continue
            }
            appliedBefore[prepared.id] = origin
            affectedPhotos.append(prepared.imported.name)
            details += [prepared.imported.name] + notes
        }
        let changeID = recordChange("AI 对话调整", before: appliedBefore)
        let proposedChanges = result.changes?.count ?? 0
        let skipped = proposedChanges - affectedPhotos.count
        let reply: String
        if proposedChanges == 0 {
            let advice = result.reply ?? "没有生成可执行的调整。"
            let unsupportedClaims = ["已完成", "已经完成", "已经调整", "我已", "已为", "已帮", "已修复", "已去除", "已开启", "已关闭", "已经将", "已将"]
            reply = unsupportedClaims.contains(where: { advice.contains($0) })
                ? "本次没有执行调整。请确认操作条件或补充需要的修改。" : advice
        }
        else if affectedPhotos.isEmpty { reply = "本次没有应用调整，请查看原因。" }
        else { reply = "已完成调整。" + (skipped > 0 ? " \(skipped) 张未调整，请查看原因。" : "") }
        chatMessages.append(ChatMessage(role: "assistant", text: reply, notes: details, affectedPhotos: affectedPhotos, changeID: changeID))
        if let selection = result.selection, selection != "none" { overlay = selection; loadAnalysis() }
        else { overlay = ""; showOriginal = false }
        schedulePreview(); refreshGrid()
        status = appliedBefore.isEmpty ? "AI 已回复" : "AI 已调整 \(appliedBefore.count) 张 · 可整批撤销"
    }

    private func reviewKeepsRequestedParameters(original: AdjustmentParameters, first: AdjustmentParameters,
                                                 reviewed: AdjustmentParameters) throws -> Bool {
        let originalFields = try EngineClient.object(original)
        let firstFields = try EngineClient.object(first)
        let reviewedFields = try EngineClient.object(reviewed)
        for key in reviewedFields.keys {
            guard let initial = originalFields[key], let firstValue = firstFields[key], let revised = reviewedFields[key] else { return false }
            let old = NSDictionary(dictionary: [key: initial])
            let middle = NSDictionary(dictionary: [key: firstValue])
            let new = NSDictionary(dictionary: [key: revised])
            if !middle.isEqual(new) && old.isEqual(middle) { return false }
        }
        return true
    }

    private func reviewAssistantChanges(_ photos: [PhotoRecord], provider: String,
                                        originalRequest: String, referenceIDs: [String], apiKey: String) async throws -> [AssistantChange] {
        assistantPhase = "正在复看调整结果"
        // 开始请求时允许取消标记先落下；拿到任务 ID 后再通知引擎取消。
        assistantApplying = false
        defer { assistantApplying = true }
        let message = "请复看已调整的照片。用户原要求：\(originalRequest)\n若结果已经合适，不要改动；只有明显偏离要求才微调。不要应用风格或执行其他工具。"
        var body: [String: Any] = ["provider": provider, "message": message, "history": [],
            "targets": try photos.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters),
                                          "quality": try EngineClient.object($0.quality)] },
            "reference_ids": referenceIDs, "undo_available": false, "image_consent": true, "review_only": true]
        if provider == "anthropic" { body["api_key"] = apiKey }
        struct Started: Decodable { var id: String }
        let started: Started = try await engine.request("assistant", body: body)
        assistantJobID = started.id
        if assistantCancellationRequested { await cancelAssistantJob(started.id); throw CancellationError() }
        while !Task.isCancelled {
            let result: AssistantJob = try await engine.get("assistant-status", query: [URLQueryItem(name: "id", value: started.id)])
            if assistantCancellationRequested { throw CancellationError() }
            if result.state == "done" { return result.changes ?? [] }
            if result.state == "error" { throw EngineError(message: result.error ?? "复看未完成") }
            if result.state == "cancelled" { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(600))
        }
        throw CancellationError()
    }

    func cancelChat() {
        guard chatting else { return }
        assistantCancellationRequested = true; assistantPhase = "正在取消…"
        if assistantApplying { assistantTask?.cancel() }
        if let id = assistantJobID { Task { await cancelAssistantJob(id) } }
    }

    private func cancelAssistantJob(_ id: String) async {
        struct Cancelled: Decodable { var cancelled: Bool }
        let _: Cancelled? = try? await engine.request("assistant-cancel", body: ["id": id])
    }
}
