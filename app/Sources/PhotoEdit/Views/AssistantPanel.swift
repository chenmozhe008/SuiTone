import SwiftUI

struct AssistantPanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("对话调整").font(.headline).fixedSize()
                Image(systemName:"info.circle").font(.caption).foregroundStyle(.secondary)
                    .help("调用本机 CLI 的既有账号与额度。发送文字和本地分析摘要，不发送照片像素；AI 目前依据统计摘要判断画面。")
                Spacer()
                Picker("对话引擎", selection: $store.assistantProvider) {
                    ForEach(store.providers) { provider in
                        Text(provider.title + (provider.available ? "" : " · 未安装")).tag(provider.id).disabled(!provider.available)
                    }
                }.labelsHidden().frame(width: 124).disabled(store.chatting)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if store.chatMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("描述你需要的调整").font(.callout)
                                Text("询问调色建议，或直接调整当前照片和整组照片。调整结果可继续编辑和撤销。")
                                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                                ForEach(["这批照片适合怎么调？", "保持自然，统一这一批的观感", "想要柔和一点的电影感"], id: \.self) { prompt in
                                    Button { store.chatDraft = prompt } label: {
                                        HStack { Text(prompt).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.left") }
                                            .font(.caption).padding(10).background(Color(white: 0.21))
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.top, 4)
                        }
                        ForEach(store.chatMessages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "你" : "修图助手")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).font(.callout).lineSpacing(4).textSelection(.enabled)
                                if !message.affectedPhotos.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label("已调整 \(message.affectedPhotos.count) 张照片", systemImage: "checkmark.circle")
                                            .font(.caption.weight(.medium))
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
                        .disabled(store.chatting || store.controlsBlocked || store.targets.isEmpty || store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.providers.contains(where: { $0.id == store.assistantProvider && $0.available }))
                }
            }.padding(16)
        }
    }
}
