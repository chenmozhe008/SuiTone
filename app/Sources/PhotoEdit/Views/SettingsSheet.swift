import SwiftUI

/// 统一的设置窗口：对话和看图（调色用）、AI 改图（生成新图用）。所有「设置」入口都打开这里。
struct SettingsSheet: View {
    @Bindable var store: WorkspaceStore
    @State private var selectedProvider = ""
    private var tab: Binding<String> { Binding(get: { store.settingsTab ?? "chat" }, set: { store.settingsTab = $0 }) }
    private func close() { store.settingsTab = nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("设置").font(.title2.weight(.semibold))
                    Spacer()
                    Button("完成", action: close).keyboardShortcut(.cancelAction)
                }
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
        }.frame(width: 780)
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
        HStack(alignment: .top, spacing: 0) {
            // 左边：全部服务和状态；右边：选中服务的设置。
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    group("本机账号（用你的订阅）", store.providers.filter { !$0.isAPI })
                    group("API 密钥（按用量付费）", store.providers.filter(\.isAPI))
                }.padding(12)
            }.frame(width: 220).background(Color(white: 0.13))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let provider = store.providers.first(where: { $0.id == selectedProvider }) {
                    detail(provider)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity)
        }.frame(height: 470).padding(.top, 16)
        .onAppear { if selectedProvider.isEmpty { selectedProvider = store.assistantProvider } }
    }

    private func group(_ title: String, _ providers: [AssistantProvider]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8)
            ForEach(providers) { provider in
                Button { selectedProvider = provider.id } label: {
                    HStack {
                        Text(provider.title).font(.callout)
                        Spacer()
                        Text(state(provider).text).font(.caption.weight(.medium)).foregroundStyle(state(provider).color)
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                        .background(selectedProvider == provider.id ? Color(white: 0.26) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func state(_ provider: AssistantProvider) -> (text: String, color: Color) {
        if provider.id == store.assistantProvider && store.assistantReady { return ("当前使用", .green) }
        if !provider.available { return ("未安装", .secondary) }
        if !provider.isAPI { return ("已安装", .primary) }
        if store.apiKeySaved(provider.id) { return ("已配置", .primary) }
        return ("未配置", .secondary)
    }

    @ViewBuilder private func detail(_ provider: AssistantProvider) -> some View {
        HStack {
            Text(provider.title).font(.headline)
            Spacer()
            if provider.id == store.assistantProvider && store.assistantReady {
                Label("当前使用", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else if provider.available && (!provider.isAPI || store.apiKeySaved(provider.id)) {
                Button("使用这个") { use(provider) }.buttonStyle(.borderedProminent)
            }
        }.padding(.horizontal, 24)
        if provider.isAPI {
            APISettingsSheet(store: store, provider: provider, done: close, onSave: { use(provider) }).id(provider.id)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(provider.available ? "使用本机已登录的 \(provider.title)，用你自己的订阅额度，不需要密钥。"
                                        : "这台电脑上没有找到 \(provider.title)。安装并登录后重新打开随心修图即可使用。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if provider.id == "codebuddy" {
                    Text("使用已验证可看图的 GLM-5V-Turbo；调用会消耗同账号的积分。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if provider.id == store.assistantProvider {
                    Text(store.visionEnabled ? "已允许它看照片预览。" : "第一次对话时会请你允许它看照片预览。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
    }

    private func use(_ provider: AssistantProvider) {
        store.assistantProvider = provider.id; store.loadAPIKey()
    }
}
