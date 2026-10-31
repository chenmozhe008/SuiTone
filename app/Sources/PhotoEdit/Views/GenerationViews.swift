import AppKit
import SwiftUI

/// 对话里的「生成新图」确认卡：写清发给谁、发什么、可能收费、结果是新图；点「生成」才发送。
struct GenerationCardView: View {
    @Bindable var store: WorkspaceStore
    let messageID: UUID
    let card: GenerationCard

    private var service: ImageService? { store.imageServices.first { $0.id == store.imageService } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.callout.weight(.semibold))
            Text(card.prompt).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            switch card.state {
            case "proposed":
                VStack(alignment: .leading, spacing: 4) {
                    row("发送到", service?.title ?? "尚未设置出图服务")
                    if let service { row("模型", store.imageModels[service.id] ?? service.defaultModel) }
                    row("比例", card.aspectRatio ?? "自动（参考原图）")
                    row("发送内容", "当前照片效果（含调色、裁切及画质调整），长边最多 2048 像素")
                    if card.selection != nil, service?.id == "ideogram" { row("选区", "发送蒙版，供模型限定编辑范围") }
                    row("费用", service.map { $0.paid ? "按\($0.title)的标准计费" : "不收费" } ?? "—")
                    row("结果", "生成新版本，当前调整固化到画面；可撤销恢复原有参数")
                }
                HStack {
                    if store.imageServiceReady {
                        Button("生成") { store.startGeneration(messageID) }.buttonStyle(.borderedProminent)
                            .disabled(store.generationTask != nil || store.controlsBlocked)
                    } else {
                        Button("设置出图服务…") { store.settingsTab = "image" }.buttonStyle(.borderedProminent)
                    }
                    Button("不用了") { store.dismissGeneration(messageID) }
                    Spacer()
                    if store.imageServiceReady { Button("更换服务…") { store.settingsTab = "image" }.buttonStyle(.link) }
                }
            case "running":
                HStack { ProgressView().controlSize(.small); Text("正在生成，通常需要十几秒到一分钟").font(.callout); Spacer()
                    Button("取消") { store.cancelGeneration(messageID) } }
            case "done":
                if let preview = card.preview {
                    LocalPhoto(path: preview).frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text("已换成生成版本，可以继续调色；点下面的撤销换回原来的照片。").font(.callout).foregroundStyle(.secondary)
                if let before = card.beforePreview, let raw = card.modelPreview,
                   store.currentID == card.photoID {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Button("生成前") { showComparison(before) }; Button("模型原图") { showComparison(raw) } }
                        HStack { Button("融合结果") { showComparison(card.preview) }; Button("返回当前") { showComparison(nil) } }
                    }.controlSize(.small)
                    Text("临时查看对照，不会替换照片；关闭软件后不保留模型原图。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case "failed":
                Text(card.error ?? "生成未完成").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("重试") { store.startGeneration(messageID) }.disabled(store.generationTask != nil)
                    // 额度用尽这类错误，光重试没用，得去服务商控制台开通或调额。
                    if let link = consoleLink(card.error) {
                        Link("去控制台开通 / 调额度", destination: link)
                    }
                    Button("换个模型…") { store.settingsTab = "image" }.buttonStyle(.link)
                    Spacer()
                }
            case "cancelled":
                Text("已取消，原照片未改变。").font(.callout).foregroundStyle(.secondary)
            default:
                Text("没有生成，原照片未改变。").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.21), in: RoundedRectangle(cornerRadius: 10))
    }

    private func showComparison(_ path: String?) {
        store.inspectorTab = "aiedit"
        store.showOriginal = false
        store.splitCompare = false
        store.versionPreview = path
    }

    /// 错误文本里附带的控制台地址（例如火山方舟开通管理页），取出来做成可点的入口。
    private func consoleLink(_ message: String?) -> URL? {
        guard let message, let start = message.range(of: "https://") else { return nil }
        let tail = message[start.lowerBound...]
        let stop = tail.firstIndex { $0 == " " || $0 == "）" || $0 == "\n" } ?? tail.endIndex
        return URL(string: String(tail[..<stop]))
    }

    private var title: String {
        switch card.state {
        case "done": return "已生成新版本"
        case "running": return "正在生成新图"
        default: return "这一步需要生成新图"
        }
    }
    private var icon: String { card.state == "done" ? "checkmark.circle" : "sparkles" }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 出图服务设置：选服务、填密钥（存钥匙串）、模型名。
struct ImageServiceSheet: View {
    @Bindable var store: WorkspaceStore
    var done: () -> Void
    @State private var selected = ""
    @State private var key = ""
    @State private var model = ""
    @State private var manualModel = false
    /// 密钥是否已经存在钥匙串（值从 UserDefaults 标记同步过来，删掉后立刻变 false）
    @State private var storedKey = false
    @State private var confirmingDelete = false
    @State private var notice: String?
    private var modelChoice: Binding<String> {
        Binding(get: { manualModel ? "\u{0}manual" : (model.isEmpty ? service?.defaultModel ?? "" : model) },
                set: { if $0 == "\u{0}manual" { manualModel = true } else { model = $0; manualModel = false } })
    }

    private var service: ImageService? { store.imageServices.first { $0.id == selected } }
    private var savedKey: Bool { storedKey }
    /// 模型 ID 只能是字母数字和 . _ -（如 doubao-seedream-5-0-pro-260628，或在线推理的 ep-2026… 接入点）。
    private var modelIssue: String? {
        let text = model.trimmingCharacters(in: .whitespaces)
        guard manualModel, !text.isEmpty else { return nil }
        guard text.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            return "模型 ID 只能有字母、数字和 . _ -，不能有空格或中文。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("服务", selection: $selected) {
                    ForEach(store.imageServices) { Text($0.title).tag($0.id) }
                }
                if selected != "mock" {
                    SecureField("API 密钥", text: $key, prompt: Text(savedKey ? "已保存，留空则不修改" : "粘贴密钥"))
                    Picker("模型", selection: modelChoice) {
                        ForEach(Array((service?.models ?? []).enumerated()), id: \.element) { index, name in
                            Text(index == 0 ? name + "（最新）" : name).tag(name)
                        }
                        if !model.isEmpty && !(service?.models ?? []).contains(model) && !manualModel { Text(model).tag(model) }
                        if selected != "ideogram" {
                            Divider()
                            Text("手动填写…").tag("\u{0}manual")
                        }
                    }
                    if manualModel {
                        TextField("模型名称", text: $model, prompt: Text("例：doubao-seedream-5-0-pro-260628"))
                        if let modelIssue {
                            Text(modelIssue).font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true).frame(height: selected == "mock" ? 80 : (manualModel ? 230 : 175))
            if selected == "jimeng" {
                HStack(spacing: 6) {
                    Text("模型 ID 以「doubao-seedream」开头，后面必须带日期后缀，例如 doubao-seedream-5-0-pro-260628；不要填 Seedream 5.0 pro 这种展示名。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("官方模型列表") { NSWorkspace.shared.open(URL(string: "https://www.volcengine.com/docs/82379/1330310")!) }
                        .buttonStyle(.link).font(.callout)
                }.padding(.horizontal, 24)
            }
            Text(notice ?? "密钥保存在本机钥匙串。出图按服务商标准计费。保存时不会调用服务，出图能力要等第一次真正生成后才算验证过。")
                .font(.callout)
                .foregroundStyle(notice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24)
            HStack(spacing: 12) {
                if selected != "mock" && savedKey {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        // 暗红底 + 白字：暗色界面里红色文字会糊在灰底上，白字红底才看得清，破坏性也一眼分明。
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.callout)
                            Text("删除密钥").font(.callout.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(red: 0.42, green: 0.15, blue: 0.15), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 1, green: 0.42, blue: 0.38).opacity(0.55), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .help("删掉这台电脑上保存的密钥（存在钥匙串里），模型选择保留")
                }
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button("保存") {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.saveImageService(selected, key: trimmed.isEmpty ? nil : trimmed,
                                           model: model.trimmingCharacters(in: .whitespaces).isEmpty ? (service?.defaultModel ?? "") : model)
                    done()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || modelIssue != nil || (selected != "mock" && key.isEmpty && !savedKey))
            }.padding(24)
        }
        .onAppear {
            selected = store.imageServices.contains { $0.id == store.imageService } ? store.imageService : (store.imageServices.first?.id ?? "")
            model = store.imageModels[selected] ?? ""
            storedKey = UserDefaults.standard.bool(forKey: "imageKeySaved." + selected)
        }
        .onChange(of: selected) { _, id in
            key = ""; manualModel = false; model = store.imageModels[id] ?? ""
            storedKey = UserDefaults.standard.bool(forKey: "imageKeySaved." + id)
            notice = nil; confirmingDelete = false
        }
        .alert("删除这台的 \(service?.title ?? "服务") 密钥？", isPresented: $confirmingDelete) {
            Button("删除密钥", role: .destructive) {
                store.removeImageServiceKey(selected)
                key = ""; storedKey = false
                notice = "密钥已从钥匙串删除。要再次出图，请重新粘贴密钥并保存。"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后这台电脑上不再保存这个密钥，需要重新粘贴才能出图。已经生成的图片不受影响，模型选择也会保留。")
        }
    }
}
