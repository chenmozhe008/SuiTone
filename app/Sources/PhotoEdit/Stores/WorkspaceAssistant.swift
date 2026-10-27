import Foundation

extension WorkspaceStore {
    func sendChat() {
        let message = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !chatting, !controlsBlocked, !targets.isEmpty else { return }
        finishEditing()
        let items = targets, before = capture(items)
        let history = chatMessages.suffix(12).map { ["role": $0.role, "text": $0.text] }
        chatMessages.append(ChatMessage(role: "user", text: message))
        chatDraft = ""; chatting = true; assistantPhase = "准备图片分析摘要"
        assistantTask = Task {
            defer { chatting = false; assistantJobID = nil; assistantTask = nil; assistantPhase = "" }
            do {
                let body: [String: Any] = ["provider": assistantProvider, "message": message, "history": history,
                    "targets": try items.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters)] }]
                struct Started: Decodable { var id: String }
                let started: Started = try await engine.request("assistant", body: body)
                assistantJobID = started.id
                while !Task.isCancelled {
                    let result: AssistantJob = try await engine.get("assistant-status", query: [URLQueryItem(name: "id", value: started.id)])
                    if result.state == "done" {
                        var appliedBefore: [String: EditSnapshot] = [:], details: [String] = [], affectedPhotos: [String] = []
                        for change in result.changes ?? [] {
                            guard let item = items.first(where: { $0.assetID == change.id }),
                                  let i = photos.firstIndex(where: { $0.id == item.id }),
                                  photos[i].assetID == item.assetID, photos[i].parameters == item.parameters else {
                                details.append("有照片在等待期间已改变，未覆盖后续调整"); continue
                            }
                            appliedBefore[item.id] = before[item.id]
                            affectedPhotos.append(item.imported.name)
                            photos[i].parameters = change.params; photos[i].lookName = "AI 调整"
                            photos[i].notes = change.notes; photos[i].previewPath = nil
                            details += [item.imported.name] + change.notes
                        }
                        recordChange("AI 对话调整", before: appliedBefore)
                        chatMessages.append(ChatMessage(role: "assistant", text: result.reply ?? "已完成", notes: details, affectedPhotos: affectedPhotos))
                        if let selection = result.selection, selection != "none" { overlay = selection; loadAnalysis() }
                        else { overlay = ""; showOriginal = false }
                        schedulePreview(); refreshGrid()
                        status = appliedBefore.isEmpty ? "AI 已回复" : "AI 已调整 \(appliedBefore.count) 张 · 可整批撤销"
                        return
                    }
                    if result.state == "error" { throw EngineError(message: result.error ?? "AI 未完成请求") }
                    if result.state == "cancelled" { chatMessages.append(ChatMessage(role: "assistant", text: "已取消，本次没有应用调整。")); return }
                    assistantPhase = result.state == "preparing" ? "准备图片分析摘要" : "\(providers.first(where: { $0.id == assistantProvider })?.title ?? "AI") 正在思考"
                    try? await Task.sleep(for: .milliseconds(600))
                }
            } catch {
                chatMessages.append(ChatMessage(role: "assistant", text: error.localizedDescription + "。本次设置未改变。"))
            }
        }
    }

    func cancelChat() {
        guard let id = assistantJobID else { return }
        Task {
            struct Cancelled: Decodable { var cancelled: Bool }
            let _: Cancelled? = try? await engine.request("assistant-cancel", body: ["id": id])
        }
    }
}
