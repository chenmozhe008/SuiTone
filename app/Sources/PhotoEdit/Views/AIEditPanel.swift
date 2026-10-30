import SwiftUI

/// 「AI 改图」工具：改哪里（整张／只改选区）→ 想改成什么 → 发给谁 → 生成；下方是这张照片的版本。
struct AIEditPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var prompt = ""
    @State private var onlySelection = true
    private let examples = ["换成雪山背景", "去掉人物并补出背景", "加一群海鸥", "天空换成晚霞"]
    private var service: ImageService? { store.imageServices.first { $0.id == store.imageService } }
    private var hasSelection: Bool { !store.selectionParts.isEmpty }
    private var card: GenerationCard? {
        store.aiEditMessageID.flatMap { id in store.chatMessages.first { $0.id == id }?.generation }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("改哪里") {
                    Picker("范围", selection: $onlySelection) {
                        Text("整张照片").tag(false)
                        Text("只改选区").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    if !onlySelection && hasSelection {
                        Text("当前改整张照片，已有选区不会用于本次生成。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        }
                    }
                }
                section("想改成什么") {
                    ZStack(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("比如：把海面换成平静的湖面，人物和天空不变").font(.callout).foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.top, 8)
                        }
                        TextEditor(text: $prompt).font(.callout).scrollContentBackground(.hidden).frame(minHeight: 70, maxHeight: 120)
                    }.padding(6).background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 8))
                    FlowLayout(spacing: 8) {
                        ForEach(examples, id: \.self) { example in
                            Button(example) { prompt = example }.buttonStyle(.plain).font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                section("发给谁", trailing: AnyView(Button("设置…") { store.settingsTab = "image" }.buttonStyle(.link))) {
                    if let service, store.imageServiceReady {
                        info("服务", service.title)
                        info("发送内容", "不带调色的原片，长边 2048 像素")
                        info("费用", service.paid ? "按\(service.title)的标准计费" : "不收费")
                        info("结果", onlySelection && hasSelection ? "只替换选区里的部分，作为新版本，可撤销" : "整张新图，作为新版本，调色照常套用，可撤销")
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("还没设置出图服务").font(.callout.weight(.semibold)).foregroundStyle(.yellow)
                            Spacer()
                            Button("去设置") { store.settingsTab = "image" }.buttonStyle(.borderedProminent)
                        }.padding(12).background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button {
                    store.startAIEdit(prompt: prompt, onlySelection: onlySelection)
                } label: {
                    Text(store.generationTask != nil ? "正在生成…" : "生成").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!store.imageServiceReady || store.generationTask != nil || store.controlsBlocked
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (onlySelection && !hasSelection))
                if let card, let id = store.aiEditMessageID { GenerationCardView(store: store, messageID: id, card: card) }
                if store.photoVersions.count > 1 {
                    section("这张照片的版本") {
                        HStack(spacing: 8) {
                            ForEach(Array(store.photoVersions.enumerated()), id: \.offset) { index, version in
                                Button {
                                    store.versionPreview = store.versionPreview == version.path || index == store.photoVersions.count - 1 ? nil : version.path
                                } label: {
                                    VStack(spacing: 4) {
                                        LocalPhoto(path: version.path, fill: true).frame(width: 84, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                                                (store.versionPreview == version.path || (store.versionPreview == nil && index == store.photoVersions.count - 1)) ? Color.white : .clear, lineWidth: 2))
                                        Text(index == store.photoVersions.count - 1 ? "当前" : version.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        Text("点一下在照片上临时查看，不会改动；要换回之前的版本用撤销。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(16)
        }
        .onAppear { onlySelection = hasSelection }
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

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
