import SwiftUI

struct AssistantPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var showingVisionConsent = false
    @State private var showingAPISettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("对话调整").font(.headline).fixedSize()
                Spacer()
                Picker("对话引擎", selection: $store.assistantProvider) {
                    Section("本机账号") {
                        ForEach(store.providers.filter { !$0.isAPI }) { provider in
                            Text(provider.title + (provider.available ? "" : " · 未安装")).tag(provider.id).disabled(!provider.available)
                        }
                    }
                    Section("API 密钥") {
                        ForEach(store.providers.filter(\.isAPI)) { provider in Text(provider.title).tag(provider.id) }
                    }
                }.labelsHidden().frame(width: 150).disabled(store.chatting)
            }.padding(16)
            if !(store.currentProvider?.available ?? false) {
                Text("此引擎暂不可用，请换一个").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            if store.usesAPI && !store.assistantReady {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("尚未完成 API 设置").font(.body.weight(.semibold)).foregroundStyle(.yellow)
                        Text("填写密钥并选择模型后才能对话").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("去设置") { showingAPISettings = true }.buttonStyle(.borderedProminent).disabled(store.chatting)
                }.padding(14)
                    .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.45), lineWidth: 1))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            } else if store.usesAPI {
                HStack {
                    Label(store.apiCredentials?.model ?? "", systemImage: "key")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("设置…") { showingAPISettings = true }.disabled(store.chatting)
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            if (store.currentProvider?.available ?? false) && !store.visionEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Label("对话调整需要 AI 看到照片", systemImage: "eye").font(.callout.weight(.medium))
                    Text("只发送缩小的预览图到 \(visionDestination)，原图留在本机。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("允许看图") { showingVisionConsent = true }.buttonStyle(.borderedProminent).disabled(store.chatting)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !store.suggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("这张照片可以试试").font(.callout.weight(.semibold))
                                FlowLayout(spacing: 8) {
                                    ForEach(store.suggestions) { card in
                                        Button { store.applySuggestion(card) } label: {
                                            Text(card.title).font(.callout).padding(.horizontal, 12).padding(.vertical, 7)
                                                .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain).disabled(store.controlsBlocked || store.chatting)
                                            .help("点一下直接调整" + store.scopeLabel)
                                    }
                                }
                            }
                        }
                        if store.chatMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("描述你需要的调整").font(.callout)
                                Text("询问调色建议，或直接调整当前照片和整组照片。调整结果可继续编辑和撤销。")
                                    .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                            }.padding(.top, 4)
                        }
                        ForEach(store.chatMessages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "你" : "修图助手")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.wasUndone ? "这次调整已撤销。" : message.text).font(.callout).lineSpacing(4).textSelection(.enabled)
                                if !message.affectedPhotos.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if !message.wasUndone {
                                            Label("已调整 \(message.affectedPhotos.count) 张照片", systemImage: "checkmark.circle")
                                                .font(.caption.weight(.medium))
                                        }
                                        ForEach(Array(message.affectedPhotos.prefix(3).enumerated()), id: \.offset) { _, name in
                                            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        if message.affectedPhotos.count > 3 {
                                            Text("另 \(message.affectedPhotos.count - 3) 张").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if let changeID = message.changeID, !message.wasUndone {
                                    Button("撤销这次调整") { store.undoAssistantChange(changeID) }
                                        .disabled(store.chatting || store.controlsBlocked || store.undoChanges.last?.id != changeID)
                                        .help(store.undoChanges.last?.id == changeID ? "撤销这次对话的全部调整" : "请先撤销之后的操作")
                                }
                                if !message.notes.isEmpty {
                                    DisclosureGroup("查看实际调整 · 可撤销") {
                                        ForEach(Array(message.notes.enumerated()), id: \.offset) { _, line in
                                            Text(line).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.font(.callout)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(Color(white: message.role == "user" ? 0.23 : 0.17))
                                .id(message.id)
                        }
                        if store.chatting {
                            HStack { ProgressView().controlSize(.small); Text(store.assistantPhase).font(.callout).foregroundStyle(.secondary) }
                                .id("thinking")
                        }
                    }.padding(16)
                }
                .onChange(of: store.chatMessages.count) { _, _ in if let last = store.chatMessages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: store.chatting) { _, running in if running { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
            VStack(alignment: .leading, spacing: 8) {
                if store.validRepairSelection {
                    HStack {
                        Text("已选择当前照片中的修复区域").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消选区") { store.clearRepairSelection() }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !store.references.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(store.references) { reference in
                                    LocalPhoto(path: reference.thumbnail, fill: true).frame(width: 52, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(alignment: .topTrailing) { RemoveReferenceButton(store: store, id: reference.id) }
                                        .help("参考图：" + reference.name)
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    ChatInputField(text: $store.chatDraft, placeholder: "说一句要求，或先在照片上框一块再说…",
                                   onSubmit: { if canSend { store.sendChat() } })
                        .frame(minHeight: 44, maxHeight: 120).accessibilityLabel("修图对话输入")
                    HStack(spacing: 12) {
                        Button { store.chooseImport(reference: true) } label: {
                            Label(store.references.isEmpty ? "参考图" : "参考图 \(store.references.count)", systemImage: "photo.badge.plus")
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help("添加一张参考图，说“照参考图调”")
                        Text("作用于\(store.scopeLabel)").foregroundStyle(.secondary)
                        Spacer()
                        if store.chatting {
                            Button { store.cancelChat() } label: {
                                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                                    .frame(width: 28, height: 28).background(Color(white: 0.85), in: Circle()).foregroundStyle(.black)
                            }.buttonStyle(.plain).help("停止")
                        } else {
                            Button { store.sendChat() } label: {
                                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                                    .frame(width: 28, height: 28)
                                    .background(canSend ? Color(white: 0.92) : Color(white: 0.35), in: Circle())
                                    .foregroundStyle(canSend ? .black : Color(white: 0.6))
                            }.buttonStyle(.plain).disabled(!canSend).help("发送（回车）")
                        }
                    }.font(.callout)
                }.padding(12)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.28), lineWidth: 1))
                Text("回车发送，Shift＋回车换行").font(.caption).foregroundStyle(.tertiary)
            }.padding(16)
        }
        .onChange(of: store.assistantProvider) { _, provider in
            store.loadAPIKey()
            if store.usesAPI && !store.assistantReady { showingAPISettings = true }
        }
        .task(id: "\(store.current?.assetID ?? "")|\(store.assistantProvider)|\(store.visionEnabled)|\(store.assistantReady)|\(store.apiCredentials?.model ?? "")") {
            if let assetID = store.current?.assetID { await store.loadSuggestions(for: assetID) }
            else { store.suggestions = [] }
        }
        .sheet(isPresented: $showingVisionConsent) {
            VisionConsentSheet(destination: visionDestination) {
                store.visionConsents.insert(store.assistantProvider)
                showingVisionConsent = false
            } cancel: {
                showingVisionConsent = false
            }
        }
        .sheet(isPresented: $showingAPISettings) {
            if let provider = store.currentProvider {
                APISettingsSheet(store: store, provider: provider) { showingAPISettings = false }
            }
        }
    }

    private var canSend: Bool {
        !store.chatting && !store.controlsBlocked && !store.targets.isEmpty && store.assistantReady && store.visionEnabled
            && !store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visionDestination: String {
        switch store.assistantProvider {
        case "codex": return "Codex / OpenAI"
        case "claude": return "Claude Code / Anthropic"
        default: return (store.currentProvider?.title ?? "AI") + " API"
        }
    }
}

private struct VisionConsentSheet: View {
    var destination: String
    var allow: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "eye").font(.title2).foregroundStyle(.secondary).frame(width: 35)
                VStack(alignment: .leading, spacing: 6) {
                    Text("允许 AI 看照片").font(.title2.weight(.semibold))
                    Text("让对话建议更贴合照片内容").foregroundStyle(.secondary)
                }
            }
            Text("开启后，当前照片的缩小预览会自动发送至所选 AI 服务，用于生成建议。对话时，所选照片、参考图和选择的区域也可能发送。原图文件保留在本机。")
                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("发送到").foregroundStyle(.secondary); Spacer(); Text(destination) }
                HStack { Text("图片大小").foregroundStyle(.secondary); Spacer(); Text("最长边约 1024 像素") }
            }.font(.callout).padding(14).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Text("调整后最多再发送一次预览以复看。使用自带账号会消耗对应额度；使用 API 密钥时，服务商可能收费。对话调整必须看图，不同意则无法使用对话，滑块和风格不受影响。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack {
                Spacer()
                Button("暂不使用", action: cancel).keyboardShortcut(.cancelAction)
                Button("允许看图", action: allow).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 540)
    }
}

private struct APISettingsSheet: View {
    @Bindable var store: WorkspaceStore
    var provider: AssistantProvider
    var done: () -> Void
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var fetched: [String] = []
    @State private var fetching = false
    @State private var manualModel = false
    @State private var result: (ok: Bool, text: String)?

    private static let manualTag = "\u{0}manual"
    /// 选「手动填写…」时显示输入框，其余选项直接作为模型名。
    private var modelChoice: Binding<String> {
        Binding(get: { manualModel ? Self.manualTag : trimmedModel },
                set: { value in
                    if value == Self.manualTag { manualModel = true } else { model = value; manualModel = false }
                })
    }
    private var savedKey: Bool { !(store.apiKeys[provider.id] ?? "").isEmpty }
    private var effectiveKey: String { key.isEmpty ? store.apiKeys[provider.id] ?? "" : cleanedKey }
    /// 去掉粘贴时混进来的空白和不可见字符，全角转半角；密钥只含 ASCII。
    private var cleanedKey: String {
        String(String.UnicodeScalarView(key.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            $0.isASCII && $0.properties.isWhitespace == false && $0.value >= 0x21 && $0.value < 0x7f
        }))
    }
    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !effectiveKey.isEmpty && !trimmedModel.isEmpty && (!provider.needsBaseUrl || !trimmedURL.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("使用 \(provider.title) API").font(.title2.weight(.semibold))
                Text("连接你自己的 API 账号。密钥保存在本机钥匙串，不写入项目文件或聊天记录。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 24)
            Form {
                Section {
                    if provider.needsBaseUrl {
                        TextField("接口地址", text: $baseURL, prompt: Text("https://…/v1"))
                    }
                    SecureField("API 密钥", text: $key, prompt: Text(savedKey ? "已保存，留空则不修改" : "粘贴密钥"))
                    Picker("模型", selection: modelChoice) {
                        if !provider.models.isEmpty {
                            Section("常用看图模型") { ForEach(provider.models, id: \.self) { Text($0).tag($0) } }
                        }
                        let others = fetched.filter { !provider.models.contains($0) }
                        if !others.isEmpty {
                            Section("服务商提供") { ForEach(others, id: \.self) { Text($0).tag($0) } }
                        }
                        if !trimmedModel.isEmpty && !provider.models.contains(trimmedModel) && !fetched.contains(trimmedModel) {
                            Text(trimmedModel).tag(trimmedModel)
                        }
                        Divider()
                        Text("手动填写…").tag(Self.manualTag)
                    }
                    if manualModel {
                        TextField("模型名称", text: $model, prompt: Text("按服务商文档填写"))
                    }
                } footer: {
                    Text("需选择能看图的模型。测试连接后，下拉里会列出这家的全部模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack(spacing: 10) {
                        Button(fetching ? "正在测试…" : "测试连接") { testConnection() }
                            .disabled(fetching || effectiveKey.isEmpty || (provider.needsBaseUrl && trimmedURL.isEmpty))
                        if fetching { ProgressView().controlSize(.small) }
                        if let result {
                            Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.ok ? Color.green : Color.orange)
                                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true).frame(height: provider.needsBaseUrl ? 330 : 290)
            HStack {
                if savedKey {
                    Button("删除密钥") { store.saveAPISettings(provider: provider.id, key: "", model: trimmedModel, baseURL: trimmedURL); done() }
                }
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.saveAPISettings(provider: provider.id, key: key.isEmpty ? nil : cleanedKey,
                                          model: trimmedModel, baseURL: trimmedURL)
                    key = ""; done()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }.frame(width: 580)
        .onAppear {
            model = store.apiModels[provider.id] ?? provider.models.first ?? ""
            baseURL = store.customBaseURL
        }
    }

    private func testConnection() {
        fetching = true; result = nil
        let secret = key.isEmpty ? effectiveKey : cleanedKey
        Task {
            defer { fetching = false }
            do {
                fetched = try await store.fetchModels(provider: provider.id, key: secret, baseURL: provider.needsBaseUrl ? trimmedURL : "")
                result = (true, fetched.isEmpty ? "连接成功" : "连接成功，可选 \(fetched.count) 个模型")
            } catch {
                result = (false, error.localizedDescription)
            }
        }
    }
}

/// 从左到右排，放不下就换行（建议标签用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
