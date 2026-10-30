import SwiftUI

struct CutoutPanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.busy { ProgressView("正在处理，请稍候…") }
            else if store.cutoutPreview == nil {
                Label("点击照片中要保留的主体", systemImage: "hand.tap")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("点中后会自动抠图并显示透明背景预览。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.cutoutPreview != nil {
                Text("抠图预览").font(.headline)
                Text("请检查主体和边缘，满意后保存。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("保存透明 PNG…") { store.saveCutout() }
                    .buttonStyle(.borderedProminent).disabled(store.busy)
                Button("重新选择") { store.resetCutout() }
                    .buttonStyle(.bordered).disabled(store.busy)
            }
            Text("使用系统主体识别，不联网。保存为原尺寸的透明 PNG，原照片不变。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(20)
    }
}
