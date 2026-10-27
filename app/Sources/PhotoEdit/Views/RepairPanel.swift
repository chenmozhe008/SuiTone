import SwiftUI

struct RepairPanel: View {
    @Bindable var store: WorkspaceStore
    private var working: Bool { store.busy || store.importing || store.batchWorking }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("移除杂物").font(.headline)
                    Spacer()
                    Text("当前照片").font(.caption).foregroundStyle(.secondary)
                }
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
                    Label(store.selectionBox == nil ? "在照片上框选杂物" : "已选中修复区域", systemImage: "rectangle.dashed")
                        .font(.subheadline.weight(.medium))
                    Text("沿杂物边缘拖出一个框，尽量少带入周围画面。").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        store.remove()
                    } label: {
                        HStack {
                            if store.busy { ProgressView().controlSize(.small) }
                            Text(store.busy ? "正在修复…" : "生成修复预览")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!store.validRepairSelection || working)
                    Button("重新选择") {
                        store.selectionBox = nil; store.repairMaskOverlay = nil
                    }.disabled(store.selectionBox == nil || working)
                    Divider()
                    DisclosureGroup("更多选项") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("去除范围", selection: $store.repairMode) {
                                Text("整个选区").tag("box")
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
                            Button("查看去除选区") { store.previewRepairMask() }
                                .disabled(!store.validRepairSelection)
                        }.padding(.top, 12)
                    }.font(.callout).disabled(working)
                        .onChange(of: store.repairMode) { _, _ in store.repairMaskOverlay = nil }
                        .onChange(of: store.repairClasses) { _, _ in store.repairMaskOverlay = nil }
                }
                if let count = store.current?.operations.count, count > 0 {
                    Divider()
                    Label("已保留 \(count) 次修复", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }
}
