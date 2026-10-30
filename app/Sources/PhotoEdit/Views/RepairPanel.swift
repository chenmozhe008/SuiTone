import SwiftUI

struct RepairPanel: View {
    @Bindable var store: WorkspaceStore
    private var working: Bool { store.busy || store.importing || store.batchWorking }
    private var hint: String {
        switch store.repairTool {
        case "brush": return "在杂物上涂抹，可以分几笔涂。涂得比杂物略大一圈效果更好。"
        case "lasso": return "按住沿杂物外沿圈一圈，松手自动闭合。"
        case "object": return "点一下要去掉的东西（行人、车、电线杆等），会自动找出它的轮廓，红色是将要去除的部分。"
        default: return "拖出一个方框。可以只去掉框里的某类东西，或保留天空。"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("移除杂物，只改当前照片。").font(.callout).foregroundStyle(.secondary)
                if store.repairDraft != nil {
                    Text("查看修补后的细节，满意后保留。").font(.callout).foregroundStyle(.secondary)
                    Picker("修复比较", selection: $store.repairShowingBefore) {
                        Text("修复前").tag(true)
                        Text("修复后").tag(false)
                    }.pickerStyle(.segmented).labelsHidden()
                    HStack {
                        Button("取消") { store.cancelRepairPreview() }
                        Spacer()
                        Button("保留修复") { store.applyRepairPreview() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    SelectionToolsCard(store: store)
                    Button {
                        store.remove()
                    } label: {
                        HStack {
                            if store.busy { ProgressView().controlSize(.small) }
                            Text(store.busy ? "正在处理…" : "生成修复预览")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!store.validRepairSelection || working)
                    FlowLayout(spacing: 8) {
                        Button("清除选区") { store.clearRepairSelection() }
                            .disabled(store.selectionBox == nil || working)
                        Button("调整选区") { store.editSelectedRegion() }
                            .disabled(!store.validRepairSelection || working)
                        Button("查看将去除的部分") { store.previewRepairMask() }
                            .disabled(!store.validRepairSelection || working)
                    }
                    if store.repairTool == "box" {
                        Divider()
                        DisclosureGroup("方框里去除什么") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("去除范围", selection: $store.repairMode) {
                                    Text("整个方框").tag("box")
                                    Text("保留天空").tag("keepSky")
                                    Text("指定对象").tag("classes")
                                }
                                if store.repairMode == "classes" {
                                    Picker("对象", selection: $store.repairClasses) {
                                        Text("栏杆与围栏").tag("railing, fence")
                                        Text("行人").tag("person")
                                        Text("车辆").tag("car, truck, bus")
                                        Text("建筑").tag("building, house")
                                        Text("电杆与路灯").tag("pole, streetlight")
                                    }
                                }
                            }.padding(.top, 12)
                        }.font(.callout).disabled(working)
                            .onChange(of: store.repairMode) { _, _ in store.repairMaskOverlay = nil }
                            .onChange(of: store.repairClasses) { _, _ in store.repairMaskOverlay = nil }
                    }
                }
                if let count = store.current?.operations.count, count > 0 {
                    Divider()
                    Label("已保留 \(count) 次修复", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }
}
