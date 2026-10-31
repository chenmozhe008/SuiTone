import SwiftUI

/// 右栏：「对话」（默认）和「调整」两页；修复、画质由画布工具栏进入，点「完成」回到原来的页。
struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    private static let titles = ["repair": "移除杂物", "quality": "画质增强", "cutout": "抠图", "selection": "选区", "aiedit": "AI 改图", "crop": "裁切与旋转"]
    private var toolMode: Bool { Self.titles[store.inspectorTab] != nil }

    var body: some View {
        VStack(spacing: 0) {
            if toolMode {
                HStack {
                    Text(Self.titles[store.inspectorTab] ?? "").font(.headline)
                    Spacer()
                    // 裁切页不设「完成」：裁完还得接着转、拉直，跳走反而要再点回来。
                    // 想换页直接点上面的页签（离开时自动应用），这里只提示一下回车。
                    if store.inspectorTab == "crop" {
                        Text("回车应用，换页点上方页签").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(store.inspectorTab == "cutout" ? "退出抠图" : "完成") { store.inspectorTab = store.lastMainTab }
                            .buttonStyle(.borderedProminent).disabled(store.busy)
                    }
                }.padding(.horizontal, 16).frame(height: 56)
            } else {
                HStack(spacing: 8) {
                    mainTab("调整", icon: "slider.horizontal.3", id: "adjust")
                    mainTab("对话", icon: "bubble.left.and.bubble.right", id: "chat")
                }.padding(.horizontal, 16).frame(height: 64)
            }
            Divider()
            switch store.inspectorTab {
            case "repair": RepairPanel(store: store)
            case "quality": QualityPanel(store: store)
            case "cutout": CutoutPanel(store: store)
            case "selection": SelectionPanel(store: store)
            case "aiedit": AIEditPanel(store: store)
            case "crop": CropPanel(store: store)
            case "adjust": AdjustPanel(store: store)
            default: AssistantPanel(store: store)
            }
        }.background(Color(white: 0.15))
            .onChange(of: store.inspectorTab) { old, tab in
                store.finishRepairTransition(to: tab)
                if old == "cutout" { store.clearRepairSelection() }
                store.repairEnabled = ["repair", "cutout", "selection"].contains(tab)
                store.cutoutPreview = nil; store.cutoutSnapshot = nil
                if tab == "cutout" { store.repairTool = "object" }
                store.overlay = ""; store.showOriginal = false; store.localRegion = nil
                if tab == "chat" || tab == "adjust" { store.lastMainTab = tab }
                if Self.titles[tab] != nil { store.grid = false }
                if tab == "adjust" { store.loadStyleTiles(); if store.analysis == nil { store.loadAnalysis() } }
                // 离开裁切页：还框着就先按框应用，然后把框整个撤掉——
                // 换到别的页还留着裁切框，会让人以为裁切还开着、点一下又进去了。
                if old == "crop", tab != "crop" {
                    if store.cropEditing { store.commitCrop() }
                    store.cropEditing = false
                    store.cropDraft = nil
                }
                // 离开 AI 改图页：那一轮的选区和临时版本预览都撤掉，回到正常画面。
                // 切到选区／移除页不算离开——这几个页签共用同一批选区。
                if old == "aiedit", !["selection", "repair"].contains(tab) { store.leaveAIEdit() }
                // 进 AI 改图页也要把已有选区画出来，不然不知道这次会改哪一块。
                if tab == "aiedit", !store.selectionParts.isEmpty, store.selectionOverlay == nil { store.refreshSelection() }
            }
    }

    private func mainTab(_ title: String, icon: String, id: String) -> some View {
        let selected = store.inspectorTab == id
        return Button { store.inspectorTab = id } label: {
            Label(title, systemImage: icon).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 42)
                .foregroundStyle(selected ? Color.white : Color(white: 0.82))
                .background(selected ? Color(red: 0.18, green: 0.42, blue: 0.57) : Color(white: 0.24), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.cyan.opacity(0.6) : Color.white.opacity(0.10)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一行滑块：名称、数值、滑条；双击名称复位。数值按 display 换算后显示。
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var reset: Double? = nil
    var display: (Double) -> String = { String(format: "%+.0f", $0 * 100) }
    var onEnd: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).frame(width: 40, alignment: .leading)
                .onTapGesture(count: 2) { if let reset { value = reset; onEnd() } }
                .help(reset == nil ? "" : "双击复位")
            Slider(value: $value, in: range, onEditingChanged: { editing in if !editing { onEnd() } })
                .controlSize(.small).accessibilityLabel(title)
            Text(display(value)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct QualityPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var showTopaz = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("作用于\(store.scopeLabel)").font(.callout).foregroundStyle(.secondary)
            Toggle("降噪", isOn: Binding(get: { store.current?.quality.denoise ?? false }, set: { value in
                store.applyQuality(denoise: value)
            }))
            Picker("分辨率", selection: Binding(get: { store.current?.quality.scale ?? 1 }, set: { value in
                store.applyQuality(scale: value)
            })) {
                Text("原尺寸").tag(1)
                Text("放大 2 倍").tag(2)
                Text("放大 4 倍").tag(4)
            }
            Text("使用本机 AI 模型放大照片。2 倍和 4 倍指宽、高分别放大；小图可优先试 2 倍。")
                .font(.callout).foregroundStyle(.secondary)
            Text("放大可能需要较长时间，也可能改变细节；调整后可预览、对比和撤销。")
                .font(.callout).foregroundStyle(.secondary)
            if store.topazPhotoURL != nil {
                Divider().padding(.vertical, 4)
                DisclosureGroup("外部工具 · Topaz Photo", isExpanded: $showTopaz) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("在 Topaz 中处理并导出后，需手动导入结果。发送时不叠加本机降噪和放大。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if store.topazTask != nil {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在准备照片…").font(.callout)
                                Button("取消") { store.topazTask?.cancel() }
                            }
                        } else {
                            Button("在 Topaz Photo 中打开…") { store.openInTopazPhoto() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("导入 Topaz 处理结果…") { store.chooseImport() }
                            .buttonStyle(.bordered)
                        Text("结果作为新照片导入，原图不变。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            Spacer()
        }.padding(16).disabled(store.controlsBlocked)
    }
}
