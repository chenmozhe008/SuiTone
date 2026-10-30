import SwiftUI

struct CutoutPanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.busy {
                ProgressView("正在处理，请稍候…")
            } else if store.cutoutPreview == nil {
                Label("在照片上点一下主体", systemImage: "hand.tap")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("点要保留的人或物，不用画圈。软件会自动去掉背景。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("看到预览后，检查边缘，再保存图片。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("主体已抠出", systemImage: "checkmark.circle")
                    .font(.headline)
                Text("方格表示透明背景。请检查主体和边缘；这只是预览，还没有保存。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("保存抠图…") { store.saveCutout() }
                    .buttonStyle(.borderedProminent).disabled(store.busy)
                Button("重新选择主体") { store.resetCutout() }
                    .buttonStyle(.bordered).disabled(store.busy)
                Text("将另存为背景透明的 PNG 图片，原照片不变。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.padding(20)
    }
}
