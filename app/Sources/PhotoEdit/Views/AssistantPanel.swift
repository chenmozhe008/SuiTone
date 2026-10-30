import SwiftUI

struct AssistantPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var showingVisionConsent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 这里只显示正在用哪个服务；选择和配置都在设置窗口里（一个地方管）。
            VStack(alignment: .leading, spacing: 8) {
                Text("对话调整").font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: store.assistantReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.assistantReady ? Color.green : Color.yellow)
                    Text(engineSummary).font(.callout).foregroundStyle(store.assistantReady ? Color.secondary : Color.yellow)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(store.assistantReady ? "更换" : "去设置") { store.settingsTab = "chat" }
                        .buttonStyle(.bordered).disabled(store.chatting)
                }
            }.padding(16)
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
                                Text("推荐调整").font(.callout.weight(.semibold))
                                Text(store.suggestionSource == "ai" ? "根据照片由 AI 推荐" : "根据原图亮度和识别区域推荐")
                                    .font(.caption).foregroundStyle(.secondary)
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
                                if let card = message.generation, !message.wasUndone {
                                    GenerationCardView(store: store, messageID: message.id, card: card)
                                }
                                if !message.variants.isEmpty {
                                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                        ForEach(message.variants) { variant in
                                            Button { store.applyVariant(variant) } label: {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    LocalPhoto(path: variant.preview, fill: true)
                                                        .frame(height: 100).frame(maxWidth: .infinity)
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                    Text(variant.title).font(.callout.weight(.medium)).lineLimit(2)
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain).disabled(store.chatting || store.controlsBlocked)
                                                .help("点击应用此方案，可撤销")
                                        }
                                    }
                                }
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
                                        .help(store.undoChanges.last?.id == changeID ? "撤销这次调整" : "请先撤销之后的操作")
                                }
                                if !message.notes.isEmpty {
                                    DisclosureGroup("查看实际调整") {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已选择当前照片中的区域").font(.callout).foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            Button("调整选区") { store.editSelectedRegion() }.disabled(store.chatting || store.controlsBlocked)
                            Button("移除所选") { store.inspectorTab = "repair" }.disabled(store.chatting || store.controlsBlocked)
                            Button("取消选区") { store.clearRepairSelection() }
                        }
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
            if store.usesAPI && !store.assistantReady { store.settingsTab = "chat" }
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
            }.preferredColorScheme(.dark)
        }

    }

    private var canSend: Bool {
        !store.chatting && !store.controlsBlocked && !store.targets.isEmpty && store.assistantReady && store.visionEnabled
            && !store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var engineSummary: String {
        guard let provider = store.currentProvider else { return "还没选对话服务" }
        guard provider.available else { return provider.title + " 没有安装，请换一个" }
        guard store.assistantReady else { return provider.title + " 还没设置好密钥或模型" }
        guard provider.isAPI else { return "正在使用 " + provider.title + "（本机账号）" }
        let model = store.apiCredentials?.model ?? ""
        let vision: String = {
            switch store.visionChecks[provider.id + "|" + model] {
            case true?: return "，支持图片识别"
            case false?: return "，看不了图"
            default: return "，看图未验证"
            }
        }()
        return "正在使用 \(provider.title)（\(model)）" + vision
    }

    private var visionDestination: String {
        switch store.assistantProvider {
        case "codex": return "Codex / OpenAI"
        case "claude": return "Claude Code / Anthropic"
        case "codebuddy": return "WorkBuddy / CodeBuddy"
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

struct APISettingsSheet: View {
    @Bindable var store: WorkspaceStore
    var provider: AssistantProvider
    var done: () -> Void
    /// 保存成功后调用（设置窗口里用来把它设为当前使用）
    var onSave: () -> Void = {}
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var fetched: [String] = []
    @State private var fetching = false
    @State private var manualModel = false
    @State private var result: (ok: Bool, text: String)?
    @State private var visionResult: (ok: Bool, text: String)?
    @State private var checkingVision = false
    private var visionLabel: String {
        switch store.visionChecks[provider.id + "|" + trimmedModel] {
        case true?: return "这个模型能看图（已测过）"
        case false?: return "上次测试：这个模型看不了图"
        default: return "看图能力未验证"
        }
    }

    private static let manualTag = "\u{0}manual"
    /// 选「手动填写…」时显示输入框，其余选项直接作为模型名。
    private var modelChoice: Binding<String> {
        Binding(get: { manualModel ? Self.manualTag : trimmedModel },
                set: { value in
                    if value == Self.manualTag { manualModel = true } else { model = value; manualModel = false }
                })
    }
    private var savedKey: Bool { store.apiKeySaved(provider.id) }
    /// 显示和按钮状态只看「存过密钥」标记；真正要用密钥（测试、保存）时才读钥匙串
    private var hasKey: Bool { !key.isEmpty || savedKey }
    private var effectiveKey: String { key.isEmpty ? store.apiKeys[provider.id] ?? "" : cleanedKey }
    private func resolvedKey() -> String {
        if !key.isEmpty { return cleanedKey }
        if let cached = store.apiKeys[provider.id], !cached.isEmpty { return cached }
        let stored = Keychain.read(provider.id) ?? ""
        store.apiKeys[provider.id] = stored
        return stored
    }
    /// 去掉粘贴时混进来的空白和不可见字符，全角转半角；密钥只含 ASCII。
    private var cleanedKey: String {
        String(String.UnicodeScalarView(key.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            $0.isASCII && $0.properties.isWhitespace == false && $0.value >= 0x21 && $0.value < 0x7f
        }))
    }
    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        hasKey && !trimmedModel.isEmpty && (!provider.needsBaseUrl || !trimmedURL.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("用你自己的 \(provider.title) API 账号。密钥保存在本机钥匙串，不写入项目文件或聊天记录。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 8)
            Form {
                Section {
                    if provider.needsBaseUrl {
                        TextField("接口地址", text: $baseURL, prompt: Text("https://…/v1"))
                    }
                    SecureField("API 密钥", text: $key, prompt: Text(savedKey ? "已保存，留空则不修改" : "粘贴密钥"))
                    Picker("模型", selection: modelChoice) {
                        if !fetched.isEmpty {
                            Section("服务商当前提供（最新在前）") {
                                ForEach(Array(fetched.enumerated()), id: \.element) { index, name in
                                    Text(index == 0 ? name + "（最新）" : name).tag(name)
                                }
                            }
                        }
                        let preset = provider.models.filter { !fetched.contains($0) }
                        if !preset.isEmpty && fetched.isEmpty {
                            Section("预置（填好密钥后会换成服务商的最新列表）") { ForEach(preset, id: \.self) { Text($0).tag($0) } }
                        }
                        if !trimmedModel.isEmpty && !fetched.contains(trimmedModel) && !(fetched.isEmpty && provider.models.contains(trimmedModel)) {
                            Text(trimmedModel).tag(trimmedModel)
                        }
                        Divider()
                        Text("手动填写…").tag(Self.manualTag)
                    }
                    if manualModel {
                        TextField("模型名称", text: $model, prompt: Text("按服务商文档填写"))
                    }
                } footer: {
                    Text("测试连接只确认密钥和地址可用、读取模型列表；看图测试会发一张程序生成的小测试图（不是你的照片），消耗很少额度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack(spacing: 10) {
                        Button(fetching ? "正在测试…" : "测试连接") { testConnection() }
                            .disabled(fetching || !hasKey || (provider.needsBaseUrl && trimmedURL.isEmpty))
                        if fetching { ProgressView().controlSize(.small) }
                        if let result {
                            Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.ok ? Color.green : Color.orange)
                                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Button(checkingVision ? "正在测试…" : "看图测试") { testVision() }
                            .disabled(checkingVision || !hasKey || trimmedModel.isEmpty || (provider.needsBaseUrl && trimmedURL.isEmpty))
                        if checkingVision { ProgressView().controlSize(.small) }
                        if let vision = visionResult {
                            Label(vision.text, systemImage: vision.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(vision.ok ? Color.green : Color.orange)
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(visionLabel).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true).frame(height: provider.needsBaseUrl ? 370 : 330)
            HStack {
                if savedKey {
                    Button("删除密钥") { store.saveAPISettings(provider: provider.id, key: "", model: trimmedModel, baseURL: trimmedURL); done() }
                }
                Spacer()
                Button("保存并使用") {
                    store.saveAPISettings(provider: provider.id, key: key.isEmpty ? nil : cleanedKey,
                                          model: trimmedModel, baseURL: trimmedURL)
                    key = ""; onSave()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }
        .onAppear {
            model = store.apiModels[provider.id] ?? provider.models.first ?? ""
            baseURL = store.customBaseURL
            // 存过密钥就自动拉一次模型列表（不收费），最新的排最前，免得名单过时
            if savedKey && (!provider.needsBaseUrl || !trimmedURL.isEmpty) { loadModels(pickNewest: store.apiModels[provider.id] == nil) }
        }
        .onChange(of: key) { _, _ in result = nil; fetched = [] }
        .onChange(of: baseURL) { _, _ in result = nil; fetched = [] }
    }

    private func testVision() {
        checkingVision = true; visionResult = nil
        let secret = resolvedKey(), name = trimmedModel
        Task {
            defer { checkingVision = false }
            do {
                let (ok, detail) = try await store.checkVision(provider: provider.id, key: secret, model: name,
                                                               baseURL: provider.needsBaseUrl ? trimmedURL : "")
                visionResult = (ok, ok ? "能看图：" + detail : "看不了图：" + detail)
            } catch { visionResult = (false, error.localizedDescription) }
        }
    }

    private func loadModels(pickNewest: Bool) {
        let secret = resolvedKey(), address = provider.needsBaseUrl ? trimmedURL : ""
        guard !secret.isEmpty else { return }
        Task {
            guard let models = try? await store.fetchModels(provider: provider.id, key: secret, baseURL: address) else { return }
            fetched = ModelList.newestFirst(models)
            if pickNewest, let newest = fetched.first { model = newest }
        }
    }

    private func testConnection() {
        fetching = true; result = nil
        let secret = resolvedKey()
        let address = provider.needsBaseUrl ? trimmedURL : ""
        Task {
            defer { fetching = false }
            do {
                let models = try await store.fetchModels(provider: provider.id, key: secret, baseURL: address)
                guard resolvedKey() == secret,
                      (provider.needsBaseUrl ? trimmedURL : "") == address else { return }
                fetched = ModelList.newestFirst(models)
                result = (true, models.isEmpty ? "接口已响应，模型能力未验证" : "已获取 \(fetched.count) 个模型，按新旧排序，能力未验证")
            } catch {
                guard resolvedKey() == secret,
                      (provider.needsBaseUrl ? trimmedURL : "") == address else { return }
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
