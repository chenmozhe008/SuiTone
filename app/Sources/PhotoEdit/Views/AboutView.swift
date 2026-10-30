import AppKit
import SwiftUI

enum AboutTab: String, CaseIterable { case intro = "介绍", changelog = "更新记录", feedback = "反馈" }

@MainActor final class AboutState: ObservableObject {
    static let shared = AboutState()
    @Published var tab: AboutTab = .intro
}

struct AboutView: View {
    @ObservedObject private var state = AboutState.shared
    @EnvironmentObject private var updates: UpdateChecker
    @State private var history: [ReleasedVersion] = []
    @State private var historyMessage: String?
    @State private var loadingHistory = false
    @State private var copied = ""
    private let repo = "chenmozhe008/SuiTone"
    private let email = "327529709@qq.com"

    /// 一条更新记录：线上（GitHub Releases）有就用线上的说明并附上发布页，没有就用 App 自带的 CHANGELOG。
    private struct ReleasedVersion {
        let version: String
        let date: String?
        let notes: [String]
        let page: URL?
    }

    private var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }
    private var repoURL: URL { URL(string: "https://github.com/\(repo)")! }

    /// 线上记录与本机更新记录按版本号合并，新的在前；同一版本不重复显示。
    private var mergedReleases: [ReleasedVersion] {
        var byVersion: [String: ReleasedVersion] = [:]
        for row in history { byVersion[row.version] = row }
        for (title, items) in localChangelog where !title.contains("开发版") {
            let parts = title.components(separatedBy: " · ")
            let version = (parts.first ?? title).trimmingCharacters(in: .whitespaces)
            let date = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            if let online = byVersion[version] {
                if online.date == nil {
                    byVersion[version] = ReleasedVersion(version: version, date: date, notes: online.notes, page: online.page)
                }
            } else {
                byVersion[version] = ReleasedVersion(version: version, date: date, notes: items, page: nil)
            }
        }
        return byVersion.values.sorted { UpdateChecker.isNewer($0.version, than: $1.version) }
    }
    private var diagnostics: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "随心修图 \(AppIdentity.version)（\(build)），\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    private var localChangelog: [(String, [String])] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [(String, [String])] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") { entries.append((String(line.dropFirst(3)), [])) }
            else if line.hasPrefix("- "), !entries.isEmpty {
                // 本机 CHANGELOG 用 Markdown 加粗关键词，界面里不渲染星号。
                entries[entries.count - 1].1.append(String(line.dropFirst(2)).replacingOccurrences(of: "**", with: ""))
            }
        }
        return entries
    }
    private let features: [(String, String, String)] = [
        ("text.bubble", "对话调整", "用自然语言描述想法，AI 分析照片后调整可继续编辑的参数。"),
        ("slider.horizontal.3", "照片调色", "用光线、颜色、质感滑块调整照片，也可应用风格或参考图。"),
        ("lasso", "局部选区", "用画笔、套索、点选或方框选择区域，支持添加和减去。"),
        ("bandage", "移除杂物", "选择不需要的内容后预览修复效果，确认后应用，可撤销。"),
        ("scissors", "主体抠图", "点击照片中的主体，检查透明预览后保存为新的 PNG。"),
        ("sparkles", "AI 改图", "通过出图服务修改整张照片或选区，生成的新版本可以撤销。")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 6) {
                    Text("随心修图").font(.system(size: 27, weight: .bold))
                    Text("跟 AI 对话，随心修出想要的照片")
                        .font(.callout)
                    HStack(spacing: 10) {
                        Text("v\(AppIdentity.version)")
                        Text("作者 @沉默者之二")
                    }.font(.callout).opacity(0.8)
                }.foregroundStyle(.white)
                Spacer()
                Link(destination: repoURL) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                        .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.white.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.35)))
                }.foregroundStyle(.white).buttonStyle(.plain)
            }.padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)
                .background(LinearGradient(colors: [Color(red: 0.18, green: 0.44, blue: 0.60), Color(red: 0.12, green: 0.28, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Picker("", selection: $state.tab) {
                ForEach(AboutTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 330).padding(.vertical, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch state.tab {
                    case .intro: intro
                    case .changelog: changelog
                    case .feedback: feedback
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }.frame(width: 680, height: 720).background(Color(white: 0.14))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("它是什么")
            Text("随心修图是一款以 AI 对话为核心的 Mac 照片编辑工具。用自己的话告诉 AI 想怎么修，它会看照片、理解要求并调整光影与色彩；调整后还可以自己继续拉滑块，让照片更符合你的想法。")
                .font(.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
            card {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.13))
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.9)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("代码完全开源").font(.body.weight(.semibold))
                        Text("github.com/\(repo)").font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Link(destination: repoURL) {
                        Label("在 GitHub 查看", systemImage: "arrow.up.right")
                            .font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color(red: 0.15, green: 0.50, blue: 0.52), in: Capsule())
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择适合你的 AI 服务").font(.body.weight(.semibold))
                    Text("使用本机已安装并登录的 Codex 或 Claude Code，或在设置中填写支持的 AI 服务 API。")
                    Text("换背景、添加内容等需要生成新画面时，可使用 AI 改图服务，确认后生成新版本。")
                }.font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            sectionTitle("能做什么")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(features, id: \.1) { feature in
                    card {
                        VStack(alignment: .leading, spacing: 9) {
                            Image(systemName: feature.0).font(.title3).foregroundStyle(.cyan)
                            Text(feature.1).font(.body.weight(.semibold))
                            Text(feature.2).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.frame(minHeight: 112, alignment: .topLeading)
                    }
                }
            }
            sectionTitle("使用说明")
            bullet("调色参数可继续手动调整；保存调整记录后，可重新打开继续编辑。")
            bullet("主体抠图另存透明 PNG，原照片保留。")
            bullet("对话和 AI 改图需要配置服务；发送照片前会说明使用的服务。出图服务可能按用量收费。")
            bullet("生成式改图会创建新图，内容和分辨率可能变化；原照片保留，操作可撤销。")
            sectionTitle("软件更新")
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("发现新版本后，左下角会显示更新入口。").font(.callout)
                    HStack(spacing: 18) {
                        Button("检查更新…") { updates.checkFromMenu() }.buttonStyle(.borderedProminent)
                        Toggle("自动检查更新", isOn: $updates.automatic).toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private var changelog: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                sectionTitle("更新记录")
                Spacer()
                Button(loadingHistory ? "正在获取…" : "刷新") { Task { await loadHistory() } }.disabled(loadingHistory)
                Link(destination: releasesPage) { Label("发布页", systemImage: "arrow.up.right.square") }
            }
            if let historyMessage {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(historyMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await loadHistory() } }.buttonStyle(.link).font(.callout)
                }
            }
            ForEach(mergedReleases, id: \.version) { release in
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(release.version).font(.body.weight(.bold)).foregroundStyle(.cyan)
                            if let date = release.date { Text(date).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Link(destination: release.page ?? releasesPage) {
                                Label(release.page == nil ? "查看" : "发布页", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                        ForEach(Array(release.notes.enumerated()), id: \.offset) { _, item in bullet(item) }
                    }
                }
            }
        }.task(id: state.tab) {
            if state.tab == .changelog && history.isEmpty && historyMessage == nil { await loadHistory() }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("使用中遇到问题，欢迎反馈").font(.headline)
                    Text("描述操作过程并附上截图，有助于定位和改进。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button { sendFeedback() } label: { Label("写反馈邮件", systemImage: "envelope.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button { copy(email) } label: { Label(copied == email ? "已复制邮箱" : email, systemImage: "doc.on.doc") }
                            .controlSize(.large)
                    }
                    Text("会打开邮件草稿，内容由你确认后发送。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            sectionTitle("反馈时请尽量包括")
            bullet("进行到哪一步、你希望得到什么结果、实际发生了什么。")
            bullet("问题是否每次都出现；若有报错，请附上完整文字或截图。")
            bullet("照片格式、使用的工具或 AI 服务；请勿发送密钥。")
            bullet("应用和 macOS 版本；邮件草稿会自动附上，也可以在下方复制。")
            card {
                HStack {
                    Text(diagnostics).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(copied == diagnostics ? "已复制" : "复制版本信息") { copy(diagnostics) }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 9) {
            Capsule().fill(Color.cyan).frame(width: 4, height: 18)
            Text(title).font(.headline)
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(white: 0.20), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.09)))
    }
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•").foregroundStyle(.cyan)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = text
    }
    private func sendFeedback() {
        var url = URLComponents(); url.scheme = "mailto"; url.path = email
        url.queryItems = [URLQueryItem(name: "subject", value: "随心修图反馈 v\(AppIdentity.version)"),
                          URLQueryItem(name: "body", value: "\n\n请描述问题和操作步骤：\n\n\(diagnostics)")]
        if let url = url.url { NSWorkspace.shared.open(url) }
    }
    @MainActor private func loadHistory() async {
        loadingHistory = true; defer { loadingHistory = false }
        // 先把上次拿到的记录显示出来，网络慢或失败时也不至于空白。
        if history.isEmpty, let cached = UserDefaults.standard.data(forKey: Keys.releases),
           let rows = Self.parseReleases(cached), !rows.isEmpty { history = rows }
        switch await fetchReleases() {
        case .ok(let data):
            UserDefaults.standard.set(data, forKey: Keys.releases)
            let rows = Self.parseReleases(data) ?? []
            history = rows
            historyMessage = rows.isEmpty ? "线上还没有发布记录，下面是应用自带的更新记录。" : nil
        case .failed(let reason):
            historyMessage = "没能刷新线上记录（\(reason)）。下面显示的是已缓存的记录和应用自带的更新记录。"
        }
    }

    private enum FetchResult { case ok(Data); case failed(String) }

    /// 不走任何代理的会话：很多人开着本地代理，出口被 GitHub 限流成 403，
    /// 而本机直连其实是通的，所以失败时要能绕开代理再试一次。
    private static let directSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private func fetchReleases() async -> FetchResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100") else {
            return .failed("地址无效")
        }
        var reasons: [String] = []
        // 先按系统设置（含代理）请求，不成功再用直连会话重试。
        for (index, session) in [URLSession.shared, Self.directSession].enumerated() {
            let route = index == 0 ? "经代理" : "直连"
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { return .ok(data) }
                reasons.append(code == 403 || code == 429
                    ? "\(route)被 GitHub 拒绝（\(code)，多为代理出口限流）"
                    : "\(route)返回 \(code)")
            } catch {
                let reason: String
                switch (error as? URLError)?.code {
                case .timedOut: reason = "连接超时"
                case .notConnectedToInternet: reason = "本机没有网络"
                case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost: reason = "连不上 api.github.com"
                default: reason = error.localizedDescription
                }
                reasons.append(route + reason)
            }
        }
        return .failed(reasons.joined(separator: "；"))
    }

    private enum Keys { static let releases = "aboutReleases" }

    /// 解析 GitHub Releases 的返回；失败返回 nil。
    private static func parseReleases(_ data: Data) -> [ReleasedVersion]? {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return releases.filter { !($0["draft"] as? Bool ?? true) && !($0["prerelease"] as? Bool ?? true) }
            .compactMap { release in
                guard let tag = release["tag_name"] as? String else { return nil }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (release["html_url"] as? String).flatMap(URL.init(string:))
                let date = (release["published_at"] as? String).map { String($0.prefix(10)) }
                let body = release["body"] as? String ?? ""
                // 优先取「这一版的变化 / 更新内容」这一节的条目，没有就退回全文里的条目。
                var section: [String] = [], all: [String] = [], inChangelog = false
                for line in body.components(separatedBy: .newlines) {
                    if line.hasPrefix("#") {
                        inChangelog = ["更新内容", "变化", "更新"].contains { line.contains($0) }
                        continue
                    }
                    guard line.hasPrefix("- ") else { continue }
                    let item = String(line.dropFirst(2)).replacingOccurrences(of: "**", with: "")
                    all.append(item)
                    if inChangelog { section.append(item) }
                }
                var notes = section.isEmpty ? all : section
                if notes.isEmpty {
                    notes = body.components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                        .prefix(4).map { $0.replacingOccurrences(of: "**", with: "") }
                }
                return ReleasedVersion(version: version, date: date, notes: notes, page: page)
            }
    }
}
