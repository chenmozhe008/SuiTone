import SwiftUI

/// 统一的设置窗口：对话和看图（调色用）、AI 改图（生成新图用）。所有「设置」入口都打开这里。
struct SettingsSheet: View {
    @Bindable var store: WorkspaceStore
    private var tab: Binding<String> { Binding(get: { store.settingsTab ?? "chat" }, set: { store.settingsTab = $0 }) }
    private func close() { store.settingsTab = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("设置").font(.title2.weight(.semibold))
                Picker("类别", selection: tab) {
                    Text("对话和看图").tag("chat")
                    Text("AI 改图").tag("image")
                }.pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 8) {
                    Text(tab.wrappedValue == "chat" ? "用于调色：理解你的话、看照片、调参数，不生成新图。"
                         : "用于生成新图：换背景、加东西、去掉大物体。每次发送前都会先请你确认，按服务商计费。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    badge
                }
            }.padding([.horizontal, .top], 24)
            if tab.wrappedValue == "chat" { chat } else { ImageServiceSheet(store: store, done: close) }
        }.frame(width: 600)
        .preferredColorScheme(.dark)  // 弹出窗口不随主窗口自动变深色，要单独指定
    }

    private var badge: some View {
        let (text, ok): (String, Bool) = {
            if tab.wrappedValue == "image" { return store.imageServiceReady ? ("已配置", true) : ("未配置", false) }
            guard store.assistantReady else { return ("未配置", false) }
            if !store.usesAPI { return ("已配置", true) }
            switch store.visionChecks[store.assistantProvider + "|" + (store.apiCredentials?.model ?? "")] {
            case true?: return ("已配置　能看图", true)
            case false?: return ("已配置　看不了图", false)
            default: return ("已配置　看图未验证", true)
            }
        }()
        return Text(text).font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(ok ? Color.green : Color.yellow)
            .background((ok ? Color.green : Color.yellow).opacity(0.15), in: Capsule())
    }

    @ViewBuilder private var chat: some View {
        Picker("对话引擎", selection: $store.assistantProvider) {
            Section("本机账号") {
                ForEach(store.providers.filter { !$0.isAPI }) { provider in
                    Text(provider.title + (provider.available ? "" : " · 未安装")).tag(provider.id).disabled(!provider.available)
                }
            }
            Section("API 密钥") { ForEach(store.providers.filter(\.isAPI)) { Text($0.title).tag($0.id) } }
        }.padding(.horizontal, 24).padding(.top, 16)
            .onChange(of: store.assistantProvider) { _, _ in store.loadAPIKey() }
        if let provider = store.currentProvider, provider.isAPI {
            APISettingsSheet(store: store, provider: provider, done: close).id(provider.id)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("使用本机已登录的 \(store.currentProvider?.title ?? "")，用你自己的订阅额度，不需要密钥。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(store.visionEnabled ? "已允许它看照片预览。" : "第一次对话时会请你允许它看照片预览。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("完成", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }.padding(24)
        }
    }
}
