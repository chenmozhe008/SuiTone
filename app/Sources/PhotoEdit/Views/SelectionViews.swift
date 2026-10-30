import SwiftUI

/// 画选区时浮在照片上方的工具条：选法、加或减、笔刷、撤销一笔、清除。
struct SelectionToolbar: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        HStack(spacing: 10) {
            Picker("选法", selection: $store.repairTool) {
                Text("画笔").tag("brush"); Text("套索").tag("lasso"); Text("点选物体").tag("object"); Text("方框").tag("box")
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Divider().frame(height: 20)
            Picker("加减", selection: $store.selectionSubtract) {
                Label("添加", systemImage: "plus").tag(false)
                Label("减去", systemImage: "minus").tag(true)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("按住 ⌥ 可临时切换为减去")
            if store.repairTool == "brush" {
                Divider().frame(height: 20)
                Text("笔刷").foregroundStyle(.secondary)
                Slider(value: $store.brushSize, in: 0.005...0.08).frame(width: 80).controlSize(.small)
            }
            Divider().frame(height: 20)
            Button { store.undoSelectionPart() } label: { Label("撤销", systemImage: "arrow.uturn.backward").fixedSize() }
                .buttonStyle(.bordered).disabled(store.selectionParts.isEmpty).help("去掉最后画的一笔")
            Button { store.clearRepairSelection() } label: { Label("清除", systemImage: "trash").fixedSize() }
                .buttonStyle(.bordered).disabled(store.selectionParts.isEmpty).help("清掉全部选区，重新画")
            Divider().frame(height: 20)
            Button { store.inspectorTab = store.lastMainTab } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold)).frame(width: 22, height: 22)
            }.buttonStyle(.borderless).help("关闭选区工具（画好的选区保留）")
        }
        .font(.callout).buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .disabled(store.busy)
    }
}

/// 「选区」工具的右栏：画了哪几笔，拿这个选区去做什么，已保存的选区可再打开。
struct SelectionPanel: View {
    @Bindable var store: WorkspaceStore
    private var saved: [String] { store.current?.parameters.manualMasks.keys.sorted() ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("在照片上涂抹或圈选。选「添加」补上漏掉的，选「减去」擦掉多余的；按住 ⌥ 可临时减去。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.selectionParts.isEmpty {
                    Text("还没有选区。点选物体可以一下选中整片天空、海面或一个人，再用画笔修边。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已画 \(store.selectionParts.count) 笔").font(.headline)
                        ForEach(Array(store.selectionParts.enumerated()), id: \.offset) { index, part in
                            HStack {
                                Text("第 \(index + 1) 笔").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                                Text(part.kind)
                                Image(systemName: part.subtract ? "minus.circle.fill" : "plus.circle.fill")
                                    .foregroundStyle(part.subtract ? Color.orange : Color.green)
                                Text(part.subtract ? "减去" : "添加").foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("用这个选区").font(.headline)
                        HStack(spacing: 8) {
                            action("局部调色", "slider.horizontal.3") { store.useSelectionForLocal() }
                            action("移除", "bandage") { store.inspectorTab = "repair" }
                            action("AI 改图", "sparkles") { store.inspectorTab = "aiedit" }
                        }
                        if store.editingSelectionKey != nil {
                            Text("正在编辑已保存的选区，点「局部调色」会更新它。").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if !saved.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已保存的选区").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(Array(saved.enumerated()), id: \.element) { index, key in
                                Button { store.editSavedSelection(key) } label: {
                                    Text("选区 \(index + 1)" + (store.editingSelectionKey == key ? "（编辑中）" : ""))
                                        .font(.callout).padding(.horizontal, 11).padding(.vertical, 6)
                                        .background(store.editingSelectionKey == key ? Color(red: 0.24, green: 0.31, blue: 0.48) : Color(white: 0.22), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                        Text("点开可以继续加减。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(16).disabled(store.controlsBlocked)
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.callout) }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}
