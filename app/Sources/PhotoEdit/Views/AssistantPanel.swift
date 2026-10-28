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
                    ForEach(store.providers) { provider in
                        Text(provider.title + (provider.available ? "" : " · 未安装")).tag(provider.id).disabled(!provider.available)
                    }
                }.labelsHidden().frame(width: 124).disabled(store.chatting)
            }.padding(16)
            HStack {
                Label(store.visionEnabled ? "看图已开启" : "看图已关闭", systemImage: store.visionEnabled ? "eye" : "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if ["codex", "anthropic"].contains(store.assistantProvider) {
                    Button(store.visionEnabled ? "关闭" : "开启") {
                        if store.visionEnabled { store.visionConsentProvider = nil }
                        else { showingVisionConsent = true }
                    }.font(.caption).disabled(store.chatting)
                } else {
                    Text("此引擎暂不可用").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.bottom, 10)
            if store.assistantProvider == "anthropic" {
                HStack {
                    Text(store.anthropicAPIKey.isEmpty ? "尚未设置 API 密钥" : "API 密钥已设置（本次运行）")
                        .font(.caption).foregroundStyle(.secondary)
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
                        .disabled(store.chatting || store.controlsBlocked || store.targets.isEmpty || store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.providers.contains(where: { $0.id == store.assistantProvider && $0.available }) || (store.assistantProvider == "anthropic" && store.anthropicAPIKey.isEmpty))
                }
            }.padding(16)
        }
        .onChange(of: store.assistantProvider) { _, provider in
            store.visionConsentProvider = nil
            if provider == "anthropic" && store.anthropicAPIKey.isEmpty { showingAPISettings = true }
        }
        .task(id: store.current?.assetID) {
            if let assetID = store.current?.assetID { await store.loadSuggestions(for: assetID) }
            else { store.suggestions = [] }
        }
        .sheet(isPresented: $showingVisionConsent) {
            VisionConsentSheet(destination: store.assistantProvider == "anthropic" ? "Claude API / Anthropic" : "Codex / OpenAI") {
                store.visionConsentProvider = store.assistantProvider
                showingVisionConsent = false
            } cancel: {
                showingVisionConsent = false
            }
        }
        .sheet(isPresented: $showingAPISettings) {
            APISettingsSheet { key in
                store.anthropicAPIKey = key
                showingAPISettings = false
            } cancel: {
                showingAPISettings = false
            }
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
            Text("开启后，当前所选照片的缩小预览、参考图和你选择的区域会发送至所选 AI 服务。原图文件保留在本机。")
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
    var save: (String) -> Void
    var cancel: () -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("使用 Claude API").font(.title2.weight(.semibold))
                Text("连接你自己的 API 账号").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("API 密钥").font(.callout)
                SecureField("在此输入密钥", text: $key)
            }
            Text("密钥仅在本次运行期间保存在内存中，不写入项目文件或聊天记录。使用 API 将按服务商标准收费；发送照片前会单独提示并征得同意。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("使用密钥") { save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = "" }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
    }
}
