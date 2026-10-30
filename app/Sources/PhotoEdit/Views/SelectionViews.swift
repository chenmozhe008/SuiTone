import SwiftUI

/// 选区的工具卡片：选法、添加／减去、笔刷大小、撤销一笔、清除。
/// 以前这块压在照片上方，挡画面、选中了也看不出来；现在放在右栏。
/// 选中态只有一种样子（蓝色实底 + 亮边），选法和添加／减去共用，
/// 不再一个蓝一个绿——那会让人以为两种颜色代表两种不同的东西。
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

            // 添加／减去是同一个开关的两个方向，做成一个分段控件：
            // 两块独立按钮并排会看着像两个不同的高亮块，分段就很清楚是「二选一」。
            HStack(spacing: 0) {
                polaritySegment("添加", icon: "plus", active: !store.selectionSubtract) {
                    store.selectionSubtract = false
                }
                polaritySegment("减去", icon: "minus", active: store.selectionSubtract) {
                    store.selectionSubtract = true
                }
            }
            .padding(3)
            .frame(height: 36)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ToolAccent.idleBorder))

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

    /// 选法与添加／减去共用同一套按钮样式：只有「选中／没选中」两种样子，
    /// 不再按按钮的语义换颜色，避免同一张卡片里出现两种强调色。
    private func toolButton(_ id: String, title: String, icon: String) -> some View {
        let selected = store.repairTool == id
        return Button { store.repairTool = id } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .chipStyle(selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(store.busy)
    }

    private func polaritySegment(_ title: String, icon: String,
                                 active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.callout.weight(active ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity).frame(height: 30)
            .chipStyle(active, corner: 7, quiet: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(title == "减去" ? "从选区里挖掉这一笔（按住 ⌥ 也能临时切换）" : "把这一笔画进选区")
        .disabled(store.busy)
    }

    private func sideButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(ToolAccent.idleFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ToolAccent.idleBorder))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
        .disabled(!enabled || store.busy)
        .help(title == "撤销一笔" ? "去掉最后画的一笔" : "清掉全部选区，重新画")
    }
}

/// 卡片里所有按钮共用的外观：选中＝蓝色实底 + 亮边，没选中＝同一块灰底。
/// `quiet` 是分段控件里的非选中段：不画底、不描边，让整条看起来是一个开关。
private struct ChipStyle: ViewModifier {
    var active: Bool
    var corner: CGFloat = 9
    var quiet = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? Color.white : Color.white.opacity(quiet ? 0.62 : 0.72))
            .background {
                if active {
                    RoundedRectangle(cornerRadius: corner).fill(ToolAccent.blue.fill)
                } else if !quiet {
                    RoundedRectangle(cornerRadius: corner).fill(ToolAccent.idleFill)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner)
                    .stroke(active ? ToolAccent.blue.border : (quiet ? Color.clear : ToolAccent.idleBorder),
                            lineWidth: active ? 1.2 : 0.8)
            }
    }
}

private extension View {
    func chipStyle(_ active: Bool, corner: CGFloat = 9, quiet: Bool = false) -> some View {
        modifier(ChipStyle(active: active, corner: corner, quiet: quiet))
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
                                    .foregroundStyle(Color.white.opacity(0.45))
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
