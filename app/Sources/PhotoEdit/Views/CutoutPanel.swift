import SwiftUI

struct CutoutPanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("点照片中的人物或物体，生成透明背景预览。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("这是基础自动抠图，头发和复杂边缘可能不准确，请先检查预览。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.busy { ProgressView("正在识别主体…") }
            if store.cutoutPreview != nil {
                Button("保存透明 PNG…") { store.saveCutout() }
                    .buttonStyle(.borderedProminent).disabled(store.busy)
                Text("保存为新文件，原照片不变。") .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(20)
    }
}
