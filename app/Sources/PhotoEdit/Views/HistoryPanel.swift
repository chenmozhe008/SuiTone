import SwiftUI

/// 按需打开的图集调整记录。
struct HistoryPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var hoveredStep: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("历史记录").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if !store.albumSteps.isEmpty {
                    Button("清空") { store.clearSteps() }.buttonStyle(.plain)
                        .font(.callout).foregroundStyle(.secondary).help("清空记录，画面不变")
                }
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            Text("当前图集的操作记录").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
            if store.albumSteps.isEmpty {
                Text(store.currentAlbumID == nil ? "打开图集后，调整记录显示在这里。" : "暂无调整记录。")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.albumSteps.reversed())) { step in stepRow(step) }
                    }
                }
            }
        }
    }

    private func stepRow(_ step: LibraryStep) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(step.label).font(.callout).lineLimit(1)
                Text("\(step.states.count) 张 · \(step.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hoveredStep == step.id {
                Button { store.deleteStep(step) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("删除这条记录，画面不变")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { store.revertToStep(step) }
        .onHover { inside in hoveredStep = inside ? step.id : (hoveredStep == step.id ? nil : hoveredStep) }
        .help("回到这一步的调整")
    }
}
