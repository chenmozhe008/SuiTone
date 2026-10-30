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
                    row("发送内容", "这张照片不带调色的原片，长边 2048 像素")
                    row("费用", service.map { $0.paid ? "按\($0.title)的标准计费" : "不收费" } ?? "—")
                    row("结果", card.selection == nil ? "一张新图片，你的调色照常套在上面；原图保留，可撤销" : "只替换选区里的部分，原尺寸保留；可撤销")
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
            case "failed":
                Text(card.error ?? "生成未完成").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("重试") { store.startGeneration(messageID) }.disabled(store.generationTask != nil)
            case "cancelled":
                Text("已取消，原照片未改变。").font(.callout).foregroundStyle(.secondary)
            default:
                Text("没有生成，原照片未改变。").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.21), in: RoundedRectangle(cornerRadius: 10))
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

    private var service: ImageService? { store.imageServices.first { $0.id == selected } }
    private var savedKey: Bool { UserDefaults.standard.bool(forKey: "imageKeySaved." + selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("服务", selection: $selected) {
                    ForEach(store.imageServices) { Text($0.title).tag($0.id) }
                }
                if selected != "mock" {
                    SecureField("API 密钥", text: $key, prompt: Text(savedKey ? "已保存，留空则不修改" : "粘贴密钥"))
                    TextField("模型", text: $model, prompt: Text(service?.defaultModel ?? ""))
                }
            }.formStyle(.grouped).scrollDisabled(true).frame(height: selected == "mock" ? 80 : 160)
            Text("密钥保存在本机钥匙串。出图按服务商标准计费。保存时不会调用服务，出图能力要等第一次真正生成后才算验证过。")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24)
            HStack {
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button("保存") {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.saveImageService(selected, key: trimmed.isEmpty ? nil : trimmed,
                                           model: model.trimmingCharacters(in: .whitespaces).isEmpty ? (service?.defaultModel ?? "") : model)
                    done()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || (selected != "mock" && key.isEmpty && !savedKey))
            }.padding(24)
        }
        .onAppear {
            selected = store.imageServices.contains { $0.id == store.imageService } ? store.imageService : (store.imageServices.first?.id ?? "")
            model = store.imageModels[selected] ?? ""
        }
        .onChange(of: selected) { _, id in key = ""; model = store.imageModels[id] ?? "" }
    }
}
