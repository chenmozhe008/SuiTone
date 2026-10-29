import SwiftUI

/// 右栏：「对话」（默认）和「调整」两页；修复、画质由画布工具栏进入，点「完成」回到原来的页。
struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    private var toolMode: Bool { store.inspectorTab == "repair" || store.inspectorTab == "quality" }

    var body: some View {
        VStack(spacing: 0) {
            if toolMode {
                HStack {
                    Text(store.inspectorTab == "repair" ? "修复" : "画质").font(.headline)
                    Spacer()
                    Button("完成") { store.inspectorTab = store.lastMainTab }
                        .buttonStyle(.borderedProminent).disabled(store.busy)
                }.padding(.horizontal, 16).frame(height: 56)
            } else {
                Picker("面板", selection: $store.inspectorTab) {
                    Text("对话").tag("chat")
                    Text("调整").tag("adjust")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220).frame(maxWidth: .infinity).frame(height: 56)
            }
            Divider()
            switch store.inspectorTab {
            case "repair": RepairPanel(store: store)
            case "quality": QualityPanel(store: store)
            case "adjust": AdjustPanel(store: store)
            default: AssistantPanel(store: store)
            }
        }.background(Color(white: 0.15))
            .onChange(of: store.inspectorTab) { _, tab in
                let selectionForChat = tab == "chat" && store.repairDraft == nil ? store.selectionBox : nil
                store.cancelRepairPreview()
                if let selectionForChat { store.selectionBox = selectionForChat }
                store.repairEnabled = tab == "repair"
                store.overlay = ""; store.showOriginal = false; store.localRegion = nil
                if tab == "chat" || tab == "adjust" { store.lastMainTab = tab }
                if tab == "repair" || tab == "quality" { store.grid = false }
                if tab == "adjust" { store.loadStyleTiles(); if store.analysis == nil { store.loadAnalysis() } }
            }
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
            Text("调整后可预览、对比和撤销。放大首次生成较慢。").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(16).disabled(store.controlsBlocked)
    }
}
