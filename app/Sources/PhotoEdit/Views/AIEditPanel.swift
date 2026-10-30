import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 「AI 改图」工具：改哪里（整张／只改选区）→ 想改成什么 → 发给谁 → 生成；下方是这张照片的版本。
struct AIEditPanel: View {
    @Bindable var store: WorkspaceStore
    @StateObject private var editor = MentionEditorModel()
    @State private var onlySelection = true
    @State private var referencePaths: [String] = []
    @State private var showMention = false
    private let examples = ["换成雪山背景", "去掉人物并补出背景", "加一群海鸥", "天空换成晚霞"]
    private var service: ImageService? { store.imageServices.first { $0.id == store.imageService } }
    /// 这个模型能加几张参考图（含原图在内的官方上限；0 表示不给加）
    private var limit: Int { store.imageReferenceLimit }
    private var hasSelection: Bool { !store.selectionParts.isEmpty }
    private var card: GenerationCard? {
        store.aiEditMessageID.flatMap { id in store.chatMessages.first { $0.id == id }?.generation }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("编辑范围") {
                    Picker("范围", selection: $onlySelection) {
                        Text("整张照片").tag(false)
                        Text("只改选区").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    if !onlySelection && hasSelection {
                        HStack {
                            Text("当前改整张照片，已有选区不会用于本次生成。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("清除选区") { store.clearRepairSelection() }.buttonStyle(.link)
                        }
                    }
                    if onlySelection && !hasSelection {
                        HStack {
                            Text("还没有选区。").font(.callout).foregroundStyle(.secondary)
                            Button("画选区") { store.inspectorTab = "selection" }.buttonStyle(.link)
                        }
                    } else if onlySelection {
                        HStack {
                            Text("已选 \(store.selectionParts.count) 笔，只替换这块，其余像素不动。").font(.callout).foregroundStyle(.secondary)
                            Button("编辑选区") { store.inspectorTab = "selection" }.buttonStyle(.link)
                            Button("清除选区") { store.clearRepairSelection() }.buttonStyle(.link)
                        }
                    }
                }
                section("参考图（可选）", trailing: limit > 0 ? AnyView(
                    Text("最多 \(limit) 张").font(.caption).foregroundStyle(.secondary)
                ) : nil) {
                    if limit == 0 {
                        Text(store.imageModelName.isEmpty ? "先在设置里选择 AI 改图服务和模型，再添加参考图。" : "当前的 \(store.imageModelName) 按官方文档不能附加参考图。如需使用参考图，请在设置中更换模型。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if referencePaths.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("添加参考图，借鉴其中的元素、色彩或风格。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("添加参考图…", systemImage: "plus") { addReferences() }
                        }
                    } else {
                        ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(referencePaths.enumerated()), id: \.element) { index, path in
                                Button {
                                    referencePaths.removeAll { $0 == path }
                                } label: {
                                    LocalPhoto(path: path, fill: true).frame(width: 74, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25)))
                                        .overlay(alignment: .bottomLeading) { figureBadge("图\(index + 2)") }
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                                                .foregroundStyle(.white, .black).padding(3)
                                        }
                                }.buttonStyle(.plain).disabled(editor.hasReferenceMentions)
                                    .help(editor.hasReferenceMentions ? "先从提示词中删除参考图引用，再移除参考图" : "点一下移除这张参考图")
                            }
                            if referencePaths.count < limit {
                                Button { addReferences() } label: {
                                    VStack {
                                        Image(systemName: "plus").font(.system(size: 17))
                                        Text("添加").font(.caption2)
                                    }.frame(width: 74, height: 54)
                                    .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                        }.scrollIndicators(.visible)
                        Text("参考图将与照片一起发送给 AI。已添加 \(referencePaths.count)／\(limit) 张。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if editor.hasReferenceMentions {
                            Text("移除参考图前，请先删除提示词中的参考图引用。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                section("编辑要求") {
                    composer
                    if !referencePaths.isEmpty {
                        Text("输入 @ 可引用原图或参考图。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(examples, id: \.self) { example in
                            Button(example) {
                                if editor.isEmpty { editor.setText(example) }
                                else { editor.view?.appendText("\n" + example) }
                            }.buttonStyle(.plain).font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                section("生成服务", trailing: AnyView(Button("设置…") { store.settingsTab = "image" }.buttonStyle(.link))) {
                    if let service, store.imageServiceReady {
                        info("服务", service.title)
                        info("发送内容", "不带调色的原片，长边 2048 像素" + (referencePaths.isEmpty ? "" : "＋\(referencePaths.count) 张参考图（按缩略图顺序跟在后面）"))
                        info("费用", service.paid ? "按\(service.title)的标准计费" : "不收费")
                        info("结果", onlySelection && hasSelection ? "只替换选区里的部分，作为新版本，可撤销" : "整张新图，作为新版本，调色照常套用，可撤销")
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("还没设置 AI 改图 API").font(.callout.weight(.semibold)).foregroundStyle(.yellow)
                            Spacer()
                            Button("去设置") { store.settingsTab = "image" }.buttonStyle(.borderedProminent)
                        }.padding(12).background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button {
                    store.startAIEdit(prompt: editor.text, onlySelection: onlySelection, references: referencePaths)
                } label: {
                    Text(store.generationTask != nil ? "正在生成…" : "生成").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!store.imageServiceReady || store.generationTask != nil || store.controlsBlocked
                              || editor.isEmpty || (onlySelection && !hasSelection))
                if store.imageServiceReady && onlySelection && !hasSelection { Text("请先选择编辑区域。") .font(.callout).foregroundStyle(.secondary) }
                else if store.imageServiceReady && editor.isEmpty { Text("请输入编辑要求。") .font(.callout).foregroundStyle(.secondary) }
                if let card, let id = store.aiEditMessageID { GenerationCardView(store: store, messageID: id, card: card) }
                if store.photoVersions.count > 1 {
                    section("这张照片的版本") {
                        ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(store.photoVersions.enumerated()), id: \.offset) { index, version in
                                Button {
                                    store.versionPreview = store.versionPreview == version.path || index == store.photoVersions.count - 1 ? nil : version.path
                                } label: {
                                    VStack(spacing: 4) {
                                        LocalPhoto(path: version.thumb, fill: true).frame(width: 84, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                                                (store.versionPreview == version.path || (store.versionPreview == nil && index == store.photoVersions.count - 1)) ? Color.white : .clear, lineWidth: 2))
                                        Text(index == store.photoVersions.count - 1 ? "当前" : version.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        }
                        Text("点一下在照片上临时查看，不会改动；要换回之前的版本用撤销。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(16)
        }
        .onAppear {
            onlySelection = hasSelection
            // 验收截图时用启动参数 -aiRefs 预置参考图；正常使用这里是空的。
            if referencePaths.isEmpty, !store.aiEditReferences.isEmpty { referencePaths = store.aiEditReferences }
            if store.aiAutoPrompt, figures.count > 1 {
                editor.setText("把 ")
                editor.insert(name: figures[1].name, path: figures[1].path)
                editor.view?.appendText(" 的色调，套到 ")
                editor.insert(name: figures[0].name, path: figures[0].path)
                editor.view?.appendText(" 上，保持构图不变")
                let sent = editor.text
                store.status = "验收：提示词 = \(sent)"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    store.startAIEdit(prompt: sent, onlySelection: false, references: referencePaths)
                }
            }
            if store.aiMentionDemo {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    editor.setText("")
                    for figure in figures.prefix(3) { editor.insert(name: figure.name, path: figure.path) }
                }
            }
        }
        // 在这一页画出选区就默认只改选区；选区清空则改回整张
        .onChange(of: store.selectionParts.isEmpty) { _, empty in onlySelection = !empty }
        .onDisappear { store.versionPreview = nil }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); trailing }
            content()
        }
    }

    /// 选参考图：跟照片一起发给 AI（姿势、风格、物品）。张数上限按服务商官方文档，超出的不再添加。
    private func addReferences() {
        let room = limit - referencePaths.count
        guard room > 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "选择参考图，还可添加 \(room) 张"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            if !referencePaths.contains(path) { referencePaths.append(path) }
        }
        if referencePaths.count > limit {
            referencePaths = Array(referencePaths.prefix(limit))
            store.status = "\(store.imageModelName) 最多 \(limit) 张参考图，多选的部分没有加上"
        }
    }

    /// 输入框：默认只有占位提示；打了 @ 才在框内展开可引用的图片，选完以图片块的形式嵌进文字。
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            MentionEditor(model: editor,
                          placeholder: "例如：把背景换成雪山，保留人物和构图",
                          onMention: { if !figures.isEmpty { showMention = true } },
                          onTyping: { if showMention { showMention = false } })
                .frame(height: showMention ? 54 : 74)
            if showMention { mentionList }
        }
        .padding(10)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            showMention ? Color(red: 0.62, green: 0.45, blue: 1.0).opacity(0.7) : Color.white.opacity(0.06),
            lineWidth: 1))
    }

    /// 缩略图上的编号角标：实底黑底白字，图再小也能看清是第几张。
    private func figureBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Color.black.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.6))
            .padding(3)
    }

    /// @ 之后在输入框里展开的候选列表：图片 + 编号 + 是原图还是参考图。
    private var mentionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("选择要引用的图片").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("收起") { showMention = false }.buttonStyle(.link).font(.caption)
            }.padding(.horizontal, 2).padding(.bottom, 4)
            Divider().overlay(Color.white.opacity(0.08))
            ForEach(Array(figures.enumerated()), id: \.offset) { index, figure in
                Button { choose(figure.name) } label: {
                    HStack(spacing: 8) {
                        LocalPhoto(path: figure.path, fill: true).frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(figure.name).font(.callout)
                        Text(index == 0 ? "原图" : "参考图").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 2).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().overlay(Color.white.opacity(0.06))
            }
        }
    }

    private var figures: [(name: String, path: String)] {
        var out: [(name: String, path: String)] = []
        if let photo = store.current { out.append(("图1", photo.imported.path)) }
        for (index, path) in referencePaths.enumerated() { out.append(("图\(index + 2)", path)) }
        return out
    }


    /// 选 @ 列表里的某一项：把刚打的 @ 换成图片块，文字里也就跟着显示成图片了。
    private func choose(_ name: String) {
        showMention = false
        editor.view?.deleteTrailingAtSign()
        let path = figures.first { $0.name == name }?.path
        editor.insert(name: name, path: path)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
