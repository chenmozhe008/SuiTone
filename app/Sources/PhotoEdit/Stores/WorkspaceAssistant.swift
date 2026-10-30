import Foundation

extension WorkspaceStore {
    func undoAssistantChange(_ changeID: UUID) {
        guard !chatting, !controlsBlocked else { return }
        finishEditing()
        guard undoChanges.last?.id == changeID else {
            status = "这次调整之后还有其他操作，请按顺序撤销"
            return
        }
        undo()
    }

    func loadSuggestions(for assetID: String) async {
        suggestions = []; suggestionSource = "local"
        let provider = assistantProvider, useVision = visionEnabled, credentials = apiCredentials, ready = assistantReady
        let cacheKey = provider + ":" + assetID
        do {
            let response: SuggestionsResponse = try await engine.request("suggestions", body: ["id": assetID])
            guard !Task.isCancelled, current?.assetID == assetID else { return }
            suggestions = response.cards
        } catch {
            guard !Task.isCancelled, current?.assetID == assetID else { return }
            status = "建议暂不可用，可继续手动调整"
        }
        guard useVision, !Task.isCancelled, let photo = current, photo.assetID == assetID,
              ready else { return }
        if let cached = aiSuggestionCache[cacheKey] { suggestions = cached; suggestionSource = "ai"; return }
        struct Started: Decodable { var id: String }
        struct RecommendationJob: Decodable { var state: String; var cards: [SuggestionCard]? }
        var jobID: String?
        do {
            var body: [String: Any] = ["provider": provider, "image_consent": true,
                "targets": [["id": assetID, "params": try EngineClient.object(photo.parameters),
                             "quality": try EngineClient.object(photo.quality)]]]
            credentials?.apply(to: &body)
            guard let startedID = try await startRecommendationJob(start: {
                let started: Started = try await self.engine.request("recommendation-start", body: body)
                return started.id
            }, cancel: { id in
                struct Cancelled: Decodable { var cancelled: Bool }
                let _: Cancelled? = try? await self.engine.request("recommendation-cancel", body: ["id": id])
            }) else { return }
            jobID = startedID
            while !Task.isCancelled {
                let result: RecommendationJob = try await engine.get("recommendation-status", query: [URLQueryItem(name: "id", value: startedID)])
                if result.state == "done", let cards = result.cards {
                    guard !Task.isCancelled, current?.assetID == assetID, visionEnabled, assistantProvider == provider else { break }
                    aiSuggestionCache[cacheKey] = cards; suggestions = cards; suggestionSource = "ai"; return
                }
                if result.state == "error" || result.state == "cancelled" { return }
                try await Task.sleep(for: .milliseconds(600))
            }
        } catch { }
        if let jobID {
            struct Cancelled: Decodable { var cancelled: Bool }
            Task { let _: Cancelled? = try? await engine.request("recommendation-cancel", body: ["id": jobID]) }
        }
    }

    func startRecommendationJob(start: @escaping () async throws -> String,
                                cancel: @escaping (String) async -> Void) async throws -> String? {
        // 外层被取消后仍需等待启动响应，以便拿到编号并停止服务端任务。
        let task = Task { try await start() }
        let id = try await task.value
        if Task.isCancelled {
            await Task { await cancel(id) }.value
            return nil
        }
        return id
    }

    func applySuggestion(_ card: SuggestionCard) {
        guard !targets.isEmpty else { return }
        runPhotoOperation(.suggestion(card.id), items: targets, label: card.title)
    }

    func sendChat() {
        let message = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !chatting, !controlsBlocked, !targets.isEmpty else { return }
        guard assistantReady, visionEnabled else { return }
        finishEditing()
        let items = targets
        let undoCandidate = undoChanges.last
        let undoAvailable = undoCandidate.map { Set($0.before.keys).isSubset(of: Set(items.map(\.id))) } ?? false
        let referenceIDs = references.map(\.id), scopes = referenceScopes, only = matchOnly
        let provider = assistantProvider, sendImages = visionEnabled, credentials = apiCredentials
        let repair: (id: String, operation: RemovalOperation)? = {
            guard validRepairSelection, let photo = current, let box = selectionBox,
                  items.contains(where: { $0.id == photo.id }) else { return nil }
            return (photo.assetID, removalOperation(box))
        }()
        let history = chatMessages.suffix(12).map { ["role": $0.role, "text": $0.text] }
        chatMessages.append(ChatMessage(role: "user", text: message))
        let startedAt = Date()
        chatDraft = ""; chatting = true; assistantCancellationRequested = false; assistantPhase = "准备图片分析摘要"
        assistantTask = Task {
            defer { chatting = false; assistantJobID = nil; assistantTask = nil; assistantApplying = false; assistantPhase = "" }
            do {
                var body: [String: Any] = ["provider": provider, "message": message, "history": history,
                    "targets": try items.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters),
                                                 "quality": try EngineClient.object($0.quality)] },
                    "reference_ids": referenceIDs, "undo_available": undoAvailable, "image_consent": sendImages]
                if let repair {
                    var selection = try EngineClient.object(repair.operation)
                    selection.removeValue(forKey: "classes"); selection.removeValue(forKey: "keep")
                    selection["id"] = repair.id; body["repair_selection"] = selection
                }
                credentials?.apply(to: &body)
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
                        if let generation = result.generation {
                            let photo = items.first(where: { $0.id == currentID }) ?? items[0]
                            chatMessages.append(ChatMessage(role: "assistant", text: result.reply ?? "这个要求需要生成新图。",
                                generation: GenerationCard(photoID: photo.id, prompt: generation.prompt)))
                            return
                        }
                        if let variants = result.variants, !variants.isEmpty {
                            assistantApplying = true; assistantPhase = "正在生成方案预览"
                            await self.presentVariants(variants, reply: result.reply, items: items)
                            return
                        }
                        assistantApplying = true; assistantPhase = "正在应用调整"
                        var reviewReply: String?
                        let review: (([PhotoRecord]) async throws -> [AssistantChange])? = sendImages ? { prepared in
                            let result = try await self.reviewAssistantChanges(prepared, originals: items, provider: provider,
                                originalRequest: message, referenceIDs: referenceIDs, credentials: credentials, repair: repair)
                            reviewReply = result.reply
                            return result.changes ?? []
                        } : nil
                        await applyAssistantResult(result, items: items,
                            referenceIDs: referenceIDs, scopes: scopes, only: only, repair: repair,
                            undoCandidate: undoAvailable ? undoCandidate?.id : nil, review: review,
                            reviewFeedback: { reviewReply },
                            preserveExactValues: message.rangeOfCharacter(from: .decimalDigits) != nil)
                        return
                    }
                    if result.state == "error" { throw EngineError(message: result.error ?? "AI 未完成请求") }
                    if result.state == "cancelled" { chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return }
                    let seconds = Int(Date().timeIntervalSince(startedAt))
                    assistantPhase = result.state == "preparing" ? "准备图片分析摘要" : "\(providers.first(where: { $0.id == assistantProvider })?.title ?? "AI") 正在思考 · \(seconds) 秒"
                    try? await Task.sleep(for: .milliseconds(600))
                }
            } catch {
                let text = assistantCancellationRequested ? "已取消，本次没有应用调整。" : error.localizedDescription + "。本次设置未改变。"
                chatMessages.append(ChatMessage(role: "assistant", text: text))
            }
        }
    }

    func presentVariants(_ variants: [AssistantVariant], reply: String?, items: [PhotoRecord]) async {
        var groups: [String: UUID] = [:]
        var previews: [VariantPreview] = [], failures: [String] = []
        for variant in variants {
            guard !assistantCancellationRequested, !Task.isCancelled else {
                chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
            }
            guard let photo = items.first(where: { $0.assetID == variant.id }) else {
                failures.append(variant.title + "：未找到照片"); continue
            }
            do {
                let result: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID,
                    "params": try EngineClient.object(variant.params), "quality": try EngineClient.object(photo.quality)])
                let group = groups[photo.id] ?? UUID()
                groups[photo.id] = group
                let title = items.count > 1 ? photo.imported.name + " · " + variant.title : variant.title
                previews.append(VariantPreview(group: group, photoID: photo.id, baseline: photo.snapshot,
                    title: title, params: variant.params, notes: variant.notes, preview: result.preview))
            } catch { failures.append(variant.title + "：" + error.localizedDescription) }
        }
        guard !assistantCancellationRequested, !Task.isCancelled else {
            chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
        }
        let message = previews.isEmpty ? "没有生成可用的方案预览。" : "已生成 \(previews.count) 个方案，点击预览应用。"
        let explanation = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        chatMessages.append(ChatMessage(role: "assistant", text: message + (explanation.isEmpty ? "" : "\n" + explanation),
                                        notes: failures, variants: previews))
        status = previews.isEmpty ? "方案预览未完成" : "已生成方案，选择后应用"
    }

    func applyVariant(_ variant: VariantPreview) {
        guard !controlsBlocked, !chatting else { return }
        finishEditing()
        guard currentID == variant.photoID, let source = current else {
            status = "请先回到生成方案时的照片"; return
        }
        let snapshot = source.snapshot
        guard snapshot == variant.baseline || (variantApplied[variant.group] ?? []).contains(snapshot) else {
            status = "照片已修改，请重新生成方案，避免覆盖后续调整"; return
        }
        var prepared = prepareParameters(variant.params, name: variant.title, notes: variant.notes, on: source)
        prepared.previewPath = variant.preview; prepared.ready = true
        guard commitPrepared(prepared, expected: snapshot) else { return }
        variantApplied[variant.group, default: []].append(prepared.snapshot)
        let changeID = recordChange("应用方案：" + variant.title, before: [source.id: snapshot])
        chatMessages.append(ChatMessage(role: "assistant", text: "已应用：" + variant.title, notes: variant.notes,
                                        affectedPhotos: [source.imported.name], changeID: changeID))
        status = "已应用方案：" + variant.title
        refreshGrid()
    }

    func applyAssistantResult(_ result: AssistantJob, items: [PhotoRecord],
                              referenceIDs: [String] = [], scopes: [String: String] = [:], only: String = "all",
                              repair: (id: String, operation: RemovalOperation)? = nil, undoCandidate: UUID? = nil,
                              review: (([PhotoRecord]) async throws -> [AssistantChange])? = nil,
                              reviewFeedback: (() -> String?)? = nil,
                              preserveExactValues: Bool = false) async {
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
        var reviewAccepted = false, reviewFailure: String?
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
                        if preserveExactValues {
                            details.append(photo.imported.name + "：保留你指定的数值，已跳过复看调整")
                            continue
                        }
                        guard try reviewKeepsRequestedParameters(original: origin.parameters,
                                                                 first: photo.parameters, reviewed: change.params) else {
                            details.append(photo.imported.name + "：复看涉及未请求的参数，已跳过复看调整")
                            continue
                        }
                        let updated = try await prepareOperation(.parameters(change.params, name: "AI 调整", notes: notes + change.notes), on: photo)
                        preparedResults[index] = (updated, origin, notes + change.notes)
                    }
                }
                reviewAccepted = true
            } catch {
                if assistantCancellationRequested || Task.isCancelled {
                    chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return
                }
                reviewFailure = "复看未完成，保留首轮调整：" + error.localizedDescription
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
        else {
            let feedback = reviewAccepted ? (reviewFeedback?()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
            reply = "已完成调整。" + (skipped > 0 ? " \(skipped) 张未调整，请查看原因。" : "")
                + (feedback.isEmpty ? "" : "\n复看时：" + feedback)
                + (reviewFailure.map { "\n" + $0 } ?? "")
        }
        chatMessages.append(ChatMessage(role: "assistant", text: reply, notes: details, affectedPhotos: affectedPhotos, changeID: changeID))
        if let selection = result.selection, selection != "none" { overlay = selection; loadAnalysis() }
        else { overlay = ""; showOriginal = false }
        schedulePreview(); refreshGrid()
        status = appliedBefore.isEmpty ? "AI 已回复" : "AI 已调整 \(appliedBefore.count) 张 · 可整批撤销"
    }

    private func reviewKeepsRequestedParameters(original: AdjustmentParameters, first: AdjustmentParameters,
                                                 reviewed: AdjustmentParameters) throws -> Bool {
        guard first.manualMasks == reviewed.manualMasks else { return false }
        var baseline = original
        // 新建的局部滑块以 sourceMean 为未调整基准；不能把新字典里的全部通道都视为用户请求。
        for (name, region) in first.regions where baseline.regions[name] == nil && region.referenceCount == 0 {
            var neutralRegion = region
            neutralRegion.mean = region.sourceMean
            baseline.regions[name] = neutralRegion
        }
        let originalFields = try EngineClient.object(baseline)
        let firstFields = try EngineClient.object(first)
        let reviewedFields = try EngineClient.object(reviewed)
        func equal(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return NSDictionary(dictionary: ["value": a]).isEqual(NSDictionary(dictionary: ["value": b]))
            default: return false
            }
        }
        func permitted(_ old: Any?, _ first: Any?, _ revised: Any?) -> Bool {
            if equal(first, revised) { return true }
            if let firstMap = first as? [String: Any], let revisedMap = revised as? [String: Any] {
                let oldMap = old as? [String: Any] ?? [:]
                let keys = Set(oldMap.keys).union(firstMap.keys).union(revisedMap.keys)
                return keys.allSatisfy { permitted(oldMap[$0], firstMap[$0], revisedMap[$0]) }
            }
            if let firstArray = first as? [Any], let revisedArray = revised as? [Any] {
                guard firstArray.count == revisedArray.count else { return false }
                let oldArray = old as? [Any]
                return firstArray.indices.allSatisfy { i in
                    permitted(oldArray.flatMap { i < $0.count ? $0[i] : nil }, firstArray[i], revisedArray[i])
                }
            }
            return !equal(old, first)
        }
        return permitted(originalFields, firstFields, reviewedFields)
    }

    func reviewSelection(photos: [PhotoRecord], originals: [PhotoRecord],
                         repair: (id: String, operation: RemovalOperation)?) -> (id: String, operation: RemovalOperation)? {
        guard let repair, let original = originals.first(where: { $0.assetID == repair.id }),
              let edited = photos.first(where: { $0.id == original.id }) else { return nil }
        return (edited.assetID, repair.operation)
    }

    private func reviewAssistantChanges(_ photos: [PhotoRecord], originals: [PhotoRecord], provider: String,
                                        originalRequest: String, referenceIDs: [String], credentials: APICredentials?,
                                        repair: (id: String, operation: RemovalOperation)?) async throws -> AssistantJob {
        assistantPhase = "正在复看调整结果"
        // 开始请求时允许取消标记先落下；拿到任务 ID 后再通知引擎取消。
        assistantApplying = false
        defer { assistantApplying = true }
        let message = "请对照调整前后照片，检查目标区域的颜色方向、变化幅度和画质。用户原要求：\(originalRequest)\n不符合或无法判断时如实说明，不要夸大效果；确实合适时不要改动，明显偏离时可微调已有参数。不要应用风格或执行其他工具。"
        var body: [String: Any] = ["provider": provider, "message": message, "history": [],
            "targets": try photos.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters),
                                          "quality": try EngineClient.object($0.quality)] },
            "reference_ids": referenceIDs, "undo_available": false, "image_consent": true, "review_only": true,
            "review_before": try photos.compactMap { photo -> [String: Any]? in
                guard let source = originals.first(where: { $0.id == photo.id }) else { return nil }
                return ["id": photo.assetID, "source_id": source.assetID,
                        "params": try EngineClient.object(source.parameters), "quality": try EngineClient.object(source.quality)]
            }]
        if let selection = reviewSelection(photos: photos, originals: originals, repair: repair) {
            var payload = try EngineClient.object(selection.operation)
            payload.removeValue(forKey: "classes"); payload.removeValue(forKey: "keep")
            payload["id"] = selection.id; body["repair_selection"] = payload
        }
        credentials?.apply(to: &body)
        struct Started: Decodable { var id: String }
        let started: Started = try await engine.request("assistant", body: body)
        assistantJobID = started.id
        if assistantCancellationRequested { await cancelAssistantJob(started.id); throw CancellationError() }
        while !Task.isCancelled {
            let result: AssistantJob = try await engine.get("assistant-status", query: [URLQueryItem(name: "id", value: started.id)])
            if assistantCancellationRequested { throw CancellationError() }
            if result.state == "done" { return result }
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

    /// 从服务商读取模型名供挑选；不经过对话任务，也不发送照片。
    func fetchModels(provider: String, key: String, baseURL: String) async throws -> [String] {
        struct Models: Decodable { var models: [String] }
        var body: [String: Any] = ["provider": provider, "api_key": key]
        if !baseURL.isEmpty { body["base_url"] = baseURL }
        let response: Models = try await engine.request("assistant-models", body: body)
        return response.models
    }
}

extension WorkspaceStore {
    private func updateGeneration(_ messageID: UUID, _ body: (inout GenerationCard) -> Void) {
        guard let i = chatMessages.firstIndex(where: { $0.id == messageID }), var card = chatMessages[i].generation else { return }
        body(&card); chatMessages[i].generation = card
    }

    /// 用户在确认卡上点「生成」：渲染当前成品发给所选出图服务，结果采用为照片的新版本（可撤销）。
    func startGeneration(_ messageID: UUID) {
        guard generationTask == nil, !controlsBlocked,
              let message = chatMessages.first(where: { $0.id == messageID }), let card = message.generation,
              let photo = photos.first(where: { $0.id == card.photoID }) else { return }
        guard let service = imageServices.first(where: { $0.id == imageService }), imageServiceReady else {
            settingsTab = "image"; return
        }
        let key = service.id == "mock" ? "" : (Keychain.read("image." + service.id) ?? "")
        guard service.id == "mock" || !key.isEmpty else { settingsTab = "image"; return }
        let model = imageModels[service.id] ?? service.defaultModel
        updateGeneration(messageID) { $0.state = "running"; $0.error = nil }
        status = "正在用\(service.title)生成…"
        generationTask = Task {
            defer { generationTask = nil }
            do {
                struct Started: Decodable { var id: String }
                struct Job: Decodable { var state: String; var paths: [String]?; var error: String? }
                var body: [String: Any] = ["id": photo.assetID, "params": try EngineClient.object(photo.parameters),
                    "quality": try EngineClient.object(photo.quality), "service": service.id, "model": model,
                    "prompt": card.prompt, "image_consent": true]
                if !key.isEmpty { body["api_key"] = key }
                if let selection = card.selection { body["selection"] = try EngineClient.object(selection) }
                if !card.references.isEmpty { body["reference_paths"] = card.references }
                let started: Started = try await engine.request("image-edit-start", body: body)
                updateGeneration(messageID) { $0.jobID = started.id }
                var job = Job(state: "running")
                while job.state == "running" {
                    try await Task.sleep(for: .milliseconds(700))
                    job = try await engine.get("image-edit-status", query: [URLQueryItem(name: "id", value: started.id)])
                }
                if job.state == "cancelled" { updateGeneration(messageID) { $0.state = "cancelled" }; status = "已取消生成"; return }
                guard job.state == "done", let path = job.paths?.first else { throw EngineError(message: job.error ?? "生成未完成，原照片未改变") }
                guard let current = photos.first(where: { $0.id == photo.id }) else { return }
                let before = current.snapshot
                let prepared = try await prepareOperation(.generated(path: path), on: current)
                guard commitPrepared(prepared, expected: before) else {
                    throw EngineError(message: "生成期间照片被修改过，已保留你的修改，这次生成结果没有采用")
                }
                let changeID = recordChange("AI 生成新版本", before: [photo.id: before])
                if let i = chatMessages.firstIndex(where: { $0.id == messageID }) {
                    chatMessages[i].changeID = changeID; chatMessages[i].affectedPhotos = [photo.imported.name]
                }
                updateGeneration(messageID) { $0.state = "done"; $0.preview = prepared.previewPath }
                // 生成已采用为照片新版本，画布上的选区标注使命完成，自动清掉；
                // 卡片里保存了本次用的选区和参考图，重试时仍会用同样的内容。
                clearRepairSelection()
                status = "已换成生成版本，可撤销"
            } catch {
                updateGeneration(messageID) { $0.state = "failed"; $0.error = error.localizedDescription }
                status = "生成未完成"
            }
        }
    }

    func cancelGeneration(_ messageID: UUID) {
        guard let jobID = chatMessages.first(where: { $0.id == messageID })?.generation?.jobID else { return }
        Task { struct Done: Decodable { var cancelled: Bool }; let _: Done? = try? await engine.request("image-edit-cancel", body: ["id": jobID]) }
    }

    func dismissGeneration(_ messageID: UUID) { updateGeneration(messageID) { $0.state = "dismissed" } }

    func saveImageService(_ id: String, key: String?, model: String) {
        if let key {
            Keychain.save(key, for: "image." + id)
            UserDefaults.standard.set(!key.isEmpty, forKey: "imageKeySaved." + id)
        }
        imageModels[id] = model
        imageService = id
    }
}

extension WorkspaceStore {
    /// 看图测试：引擎只发一张程序生成的测试图，模型答对颜色才记为能看图。
    func checkVision(provider: String, key: String, model: String, baseURL: String) async throws -> (Bool, String) {
        struct Result: Decodable { var vision: Bool; var detail: String }
        var body: [String: Any] = ["provider": provider, "api_key": key, "model": model]
        if !baseURL.isEmpty { body["base_url"] = baseURL }
        let result: Result = try await engine.request("assistant-vision-check", body: body)
        visionChecks[provider + "|" + model] = result.vision
        return (result.vision, result.detail)
    }
}

extension WorkspaceStore {
    /// AI 改图面板点「生成」：在对话里记一条（可在对话里看到和撤销），用同一套确认卡流程立即生成。
    func startAIEdit(prompt: String, onlySelection: Bool, references: [String] = []) {
        guard let photo = current, !controlsBlocked, generationTask == nil else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let selection = onlySelection && !selectionParts.isEmpty ? removalOperation(selectionBox ?? [0, 0, 1, 1]) : nil
        chatMessages.append(ChatMessage(role: "user", text: "AI 改图：" + text))
        let message = ChatMessage(role: "assistant", text: selection == nil ? "按你的要求生成整张新图。" : "只改选区里的部分，其余保持原样。",
                                  generation: GenerationCard(photoID: photo.id, prompt: text, selection: selection, references: references))
        chatMessages.append(message)
        aiEditMessageID = message.id
        startGeneration(message.id)
    }

    /// 这张照片的版本：原图和每次采用的生成图（按顺序）。
    ///
    /// `path` 是画布上要显示的那张（必须和生成图同级的分辨率），`thumb` 只给版本条用。
    /// 以前把原图的缩略图当成 `path` 塞进画布，点「原图」就把一张小图拉满屏，看着就是糊的。
    var photoVersions: [(title: String, path: String, thumb: String)] {
        guard let photo = current else { return [] }
        let generated = photo.operations.compactMap(\.generated)
        return [("原图", photo.imported.original, photo.imported.thumbnail)]
            + generated.enumerated().map { ("版本 \($0.offset + 1)", $0.element, $0.element) }
    }
}
