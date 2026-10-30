import AppKit
import SwiftUI

enum AboutTab: String, CaseIterable { case intro = "介绍", changelog = "更新记录", feedback = "反馈" }

@MainActor final class AboutState: ObservableObject {
    static let shared = AboutState()
    @Published var tab: AboutTab = .intro
}

struct AboutView: View {
    @ObservedObject private var state = AboutState.shared
    @State private var checking = false
    @State private var updateMessage: String?
    @State private var releaseURL: URL?
    @State private var history: [(String, String)] = []
    @State private var historyMessage: String?
    @State private var loadingHistory = false
    private let repo = "chenmozhe008/SuiTone"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("随心修图").font(.title2.weight(.semibold))
                    Text("版本 \(AppIdentity.version)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("", selection: $state.tab) {
                ForEach(AboutTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state.tab {
                    case .intro:
                        Text("用对话和调整工具编辑照片，支持调色、选区、移除、抠图和 AI 改图。")
                        Text("AI 功能需要配置相应服务；照片会按功能说明发送给所选服务。")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(checking ? "正在检查…" : "检查更新") { Task { await checkUpdates() } }.disabled(checking)
                            if let releaseURL { Link("前往下载", destination: releaseURL) }
                        }
                        if let updateMessage { Text(updateMessage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    case .changelog:
                        Button(loadingHistory ? "正在获取…" : "查看历史发布记录") { Task { await loadHistory() } }.disabled(loadingHistory)
                        if let historyMessage { Text(historyMessage).foregroundStyle(.secondary) }
                        ForEach(Array(history.enumerated()), id: \.offset) { _, release in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(release.0).font(.headline)
                                Text(release.1).textSelection(.enabled)
                            }
                        }
                        Text("开发版 \(AppIdentity.version)").font(.headline)
                        Text("• 对话与手动调色、风格和局部调整\n• 选区、移除杂物、主体抠图和画质调整\n• AI 改图、生成版本与撤销\n• 改进抠图提示和选区操作")
                        Text("这是当前开发版本的功能记录，正式发布后将按版本记录更新内容。")
                            .foregroundStyle(.secondary)
                    case .feedback:
                        Text("使用中遇到问题，欢迎反馈。").font(.headline)
                        Text("请描述操作步骤、遇到的问题和预期结果；如有需要，可自行附上截图。")
                            .foregroundStyle(.secondary)
                        Button { sendFeedback() } label: { Label("写反馈邮件", systemImage: "envelope") }
                        Text("会打开邮件草稿，检查内容后由你决定是否发送。")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 210)
        }.padding(24).frame(width: 500)
    }

    private func sendFeedback() {
        var url = URLComponents(); url.scheme = "mailto"; url.path = "327529709@qq.com"
        url.queryItems = [URLQueryItem(name: "subject", value: "随心修图反馈 v\(AppIdentity.version)"),
                          URLQueryItem(name: "body", value: "\n\n请描述问题和操作步骤：\n\n随心修图 \(AppIdentity.version)，\(ProcessInfo.processInfo.operatingSystemVersionString)")]
        if let url = url.url { NSWorkspace.shared.open(url) }
    }

    @MainActor private func loadHistory() async {
        loadingHistory = true; defer { loadingHistory = false }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100") else { return }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                historyMessage = "暂时无法获取发布记录，仓库可能尚未发布或网络不可用。"; return
            }
            history = releases.filter { !($0["draft"] as? Bool ?? true) && !($0["prerelease"] as? Bool ?? true) }
                .compactMap { release in
                    guard let tag = release["tag_name"] as? String else { return nil }
                    let notes = (release["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return (tag, notes.isEmpty ? "这个版本没有填写更新说明。" : notes)
                }
            historyMessage = history.isEmpty ? "暂时没有正式发布记录。" : nil
        } catch { historyMessage = "无法获取发布记录，请检查网络后重试。" }
    }

    @MainActor private func checkUpdates() async {
        checking = true; defer { checking = false }
        releaseURL = nil
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = json["html_url"] as? String, let pageURL = URL(string: page),
                  pageURL.scheme == "https", pageURL.host == "github.com" else {
                updateMessage = "暂时无法获取更新信息。仓库或正式版本可能尚未发布，也可能是网络不可用。"; return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if version.compare(AppIdentity.version, options: .numeric) == .orderedDescending {
                updateMessage = "发现新版本 \(version)。请前往发布页面查看更新内容并下载。"
                releaseURL = pageURL
            } else { updateMessage = "当前版本 \(AppIdentity.version)，没有发现更新。" }
        } catch { updateMessage = "无法检查更新，请检查网络后重试。" }
    }
}
