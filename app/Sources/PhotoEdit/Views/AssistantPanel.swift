import SwiftUI

struct AssistantPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var showingVisionConsent = false
    @State private var showingAPISettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("对话调整").font(.headline).fixedSize()
                Image(systemName:"info.circle").font(.caption).foregroundStyle(.secondary)
                    .help(store.visionEnabled ? "已允许向所选 AI 服务发送照片预览；可随时关闭。" : "目前发送文字和本地分析摘要，不发送照片像素。")
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
            HStack {
                Label(store.visionEnabled ? "看图已开启" : "看图已关闭", systemImage: store.visionEnabled ? "eye" : "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.currentProvider?.available ?? false {
                    Button(store.visionEnabled ? "关闭" : "开启") {
                        if store.visionEnabled { store.visionConsentProvider = nil }
                        else { showingVisionConsent = true }
                    }.font(.caption).disabled(store.chatting)
                } else {
                    Text("此引擎暂不可用").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.bottom, 10)
            if store.usesAPI {
                HStack {
                    Text(store.assistantReady ? store.apiCredentials?.model ?? "" : "尚未完成 API 设置")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("设置") { showingAPISettings = true }.font(.caption).disabled(store.chatting)
                }.padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !store.suggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("为这张照片建议").font(.callout.weight(.semibold))
                                Text("根据画面内容，选择一项即可调整。")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(store.suggestions) { card in
                                    Button { store.applySuggestion(card) } label: {
                                        HStack { Text(card.title); Spacer(); Image(systemName: "plus") }
                                            .font(.caption).padding(10).background(Color(white: 0.21))
                                    }.buttonStyle(.plain).disabled(store.controlsBlocked || store.chatting)
                                }
                            }
                        }
                        if store.chatMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("描述你需要的调整").font(.callout)
                                Text("询问调色建议，或直接调整当前照片和整组照片。调整结果可继续编辑和撤销。")
                                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
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
                                            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        if message.affectedPhotos.count > 3 {
                                            Text("另 \(message.affectedPhotos.count - 3) 张").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if !message.notes.isEmpty {
                                    DisclosureGroup("查看实际调整 · 可撤销") {
                                        ForEach(Array(message.notes.enumerated()), id: \.offset) { _, line in
                                            Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(Color(white: message.role == "user" ? 0.23 : 0.17))
                                .id(message.id)
                        }
                        if store.chatting {
                            HStack { ProgressView().controlSize(.small); Text(store.assistantPhase).font(.caption).foregroundStyle(.secondary) }
                                .id("thinking")
                        }
                    }.padding(16)
                }
                .onChange(of: store.chatMessages.count) { _, _ in if let last = store.chatMessages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: store.chatting) { _, running in if running { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("作用于 \(store.scopeLabel)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.chatting { Button("取消") { store.cancelChat() }.font(.caption) }
                }
                if store.validRepairSelection {
                    HStack {
                        Text("已选择当前照片中的修复区域").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消选区") { store.selectionBox = nil }.font(.caption)
                    }
                }
                ZStack(alignment: .topLeading) {
                    if store.chatDraft.isEmpty {
                        Text("输入调整要求…").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 8)
                    }
                    TextEditor(text: $store.chatDraft).font(.callout).scrollContentBackground(.hidden)
                        .frame(minHeight: 65, maxHeight: 110).accessibilityLabel("修图对话输入")
                }.padding(6).background(Color(white: 0.1))
                HStack {
                    Text("⌘↩ 发送").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("发送", systemImage: "arrow.up") { store.sendChat() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(store.chatting || store.controlsBlocked || store.targets.isEmpty || store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.assistantReady)
                }
            }.padding(16)
        }
        .onChange(of: store.assistantProvider) { _, provider in
            store.visionConsentProvider = nil
            store.loadAPIKey()
            if store.usesAPI && !store.assistantReady { showingAPISettings = true }
        }
        .task(id: "\(store.current?.assetID ?? "")|\(store.assistantProvider)|\(store.visionEnabled)|\(store.assistantReady)|\(store.apiCredentials?.model ?? "")") {
            if let assetID = store.current?.assetID { await store.loadSuggestions(for: assetID) }
            else { store.suggestions = [] }
        }
        .sheet(isPresented: $showingVisionConsent) {
            VisionConsentSheet(destination: visionDestination) {
                store.visionConsentProvider = store.assistantProvider
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
                    Text("允许 AI 查看照片？").font(.title2.weight(.semibold))
                    Text("让对话建议更贴合照片内容").foregroundStyle(.secondary)
                }
            }
            Text("开启后，当前照片的缩小预览会自动发送至所选 AI 服务，用于生成建议。对话时，所选照片、参考图和选择的区域也可能发送。原图文件保留在本机。")
                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("发送到").foregroundStyle(.secondary); Spacer(); Text(destination) }
                HStack { Text("图片大小").foregroundStyle(.secondary); Spacer(); Text("最长边约 1024 像素") }
            }.font(.callout).padding(14).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Text("调整后最多再发送一次预览以复看。使用自带账号会消耗对应额度；使用 API 密钥时，服务商可能收费。你可以随时关闭看图，关闭后只发送文字和本地分析摘要。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack {
                Spacer()
                Button("暂不开启", action: cancel).keyboardShortcut(.cancelAction)
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
    @State private var result: (ok: Bool, text: String)?

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
                    HStack(spacing: 6) {
                        TextField("模型", text: $model, prompt: Text("模型名称"))
                        Menu {
                            if !provider.models.isEmpty {
                                Section("常用看图模型") { ForEach(provider.models, id: \.self) { name in Button(name) { model = name } } }
                            }
                            if !fetched.isEmpty {
                                Section("服务商提供") { ForEach(fetched, id: \.self) { name in Button(name) { model = name } } }
                            }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .disabled(provider.models.isEmpty && fetched.isEmpty)
                    }
                } footer: {
                    Text("需选择能看图的模型。测试连接后可从服务商提供的列表里选，也可直接填写。")
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
