import SwiftUI

/// 选区的工具卡片：选法、添加／减去、笔刷大小、撤销一笔、清除。
/// 以前这块压在照片上方，挡画面、选中了也看不出来；现在放在右栏，
/// 选中的那一项用带颜色的实底，跟没选的一眼就能分开。
struct SelectionToolsCard: View {
    @Bindable var store: WorkspaceStore

    private let tools: [(id: String, title: String, icon: String, hint: String)] = [
        ("brush", "画笔", "paintbrush.pointed.fill", "在要处理的地方涂抹，可以分几笔涂。"),
        ("lasso", "套索", "lasso", "沿外沿圈一圈，松手自动闭合。"),
        ("object", "点选", "hand.point.up.left.fill", "点一下要去掉的东西，自动找出它的轮廓。"),
        ("box", "方框", "rectangle.dashed", "拖出一个方框，只处理框里的内容。")
    ]

    private var hint: String {
        tools.first { $0.id == store.repairTool }?.hint ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("选法").font(.callout.weight(.semibold))
                Spacer()
                if !store.selectionParts.isEmpty {
                    Text("已画 \(store.selectionParts.count) 笔")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(tools, id: \.id) { tool in
                    toolButton(tool.id, title: tool.title, icon: tool.icon)
                }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                polarityButton("添加", icon: "plus", tone: ToolAccent.green, active: !store.selectionSubtract) {
                    store.selectionSubtract = false
                }
                polarityButton("减去", icon: "minus", tone: ToolAccent.orange, active: store.selectionSubtract) {
                    store.selectionSubtract = true
                }
            }

            if store.repairTool == "brush" {
                HStack(spacing: 10) {
                    Text("笔刷").font(.callout).foregroundStyle(.secondary)
                    Slider(value: $store.brushSize, in: 0.005...0.08).controlSize(.small)
                    Text("\(Int(store.brushSize * 1000))").font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                sideButton("撤销一笔", icon: "arrow.uturn.backward", enabled: !store.selectionParts.isEmpty) {
                    store.undoSelectionPart()
                }
                sideButton("清除", icon: "trash", enabled: !store.selectionParts.isEmpty) {
                    store.clearRepairSelection()
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.19), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.09)))
    }

    private func toolButton(_ id: String, title: String, icon: String) -> some View {
        let selected = store.repairTool == id
        return Button { store.repairTool = id } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
            .background(selected ? AnyShapeStyle(ToolAccent.blue.fill) : AnyShapeStyle(ToolAccent.idleFill),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? ToolAccent.blue.border : ToolAccent.idleBorder, lineWidth: selected ? 1.2 : 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(store.busy)
    }

    private func polarityButton(_ title: String, icon: String, tone: ToolAccent.Tone,
                                active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.callout.weight(active ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.7))
            .background(active ? AnyShapeStyle(tone.fill) : AnyShapeStyle(ToolAccent.idleFill),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(active ? tone.border : ToolAccent.idleBorder, lineWidth: active ? 1.2 : 0.8))
        }
        .buttonStyle(.plain)
        .help(title == "减去" ? "按住 ⌥ 也能临时切换成减去" : "把这一笔画进选区")
        .disabled(store.busy)
    }

    private func sideButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Color(white: 0.26), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.3))
        .disabled(!enabled || store.busy)
        .help(title == "撤销一笔" ? "去掉最后画的一笔" : "清掉全部选区，重新画")
    }
}

/// 「选区」工具的右栏：怎么画、画了哪几笔、拿这个选区去做什么，已保存的选区可再打开。
struct SelectionPanel: View {
    @Bindable var store: WorkspaceStore
    private var saved: [String] { store.current?.parameters.manualMasks.keys.sorted() ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SelectionToolsCard(store: store)
                if !store.selectionParts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(store.selectionParts.enumerated()), id: \.offset) { index, part in
                            HStack(spacing: 8) {
                                Text("第 \(index + 1) 笔").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                Text(part.kind)
                                Image(systemName: part.subtract ? "minus.circle.fill" : "plus.circle.fill")
                                    .foregroundStyle(part.subtract ? ToolAccent.orange.text : ToolAccent.green.text)
                                Text(part.subtract ? "减去" : "添加").foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("用这个选区").font(.callout.weight(.semibold))
                        HStack(spacing: 8) {
                            action("局部调色", "slider.horizontal.3") { store.useSelectionForLocal() }
                            action("移除", "bandage") { store.inspectorTab = "repair" }
                            action("AI 改图", "sparkles") { store.inspectorTab = "aiedit" }
                        }
                        if store.editingSelectionKey != nil {
                            Text("正在编辑已保存的选区，点「局部调色」会更新它。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !saved.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已保存的选区").font(.callout.weight(.semibold))
                        FlowLayout(spacing: 8) {
                            ForEach(Array(saved.enumerated()), id: \.element) { index, key in
                                Button { store.editSavedSelection(key) } label: {
                                    Text("选区 \(index + 1)" + (store.editingSelectionKey == key ? "（编辑中）" : ""))
                                        .font(.callout).padding(.horizontal, 11).padding(.vertical, 6)
                                        .background(store.editingSelectionKey == key ? Color(red: 0.24, green: 0.31, blue: 0.48) : Color(white: 0.22), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                        Text("点开可以继续加减。").font(.caption).foregroundStyle(.secondary)
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
