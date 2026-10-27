import SwiftUI

struct ExportSheet:View {
    @Bindable var store:WorkspaceStore
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("导出 \(store.targets.count) 张照片").font(.title2)
            Text("选择输出选项与保存位置。").font(.callout).foregroundStyle(.secondary)
            Picker("格式", selection: Binding(get: { store.exportOptions.format ?? "jpeg" }, set: { store.exportOptions.format = $0 })) {
                Text("JPEG").tag("jpeg")
                Text("PNG").tag("png")
            }
            Toggle("添加出片信息条",isOn:$store.exportOptions.infoBar)
            if store.exportOptions.infoBar {
                TextField("地点",text:$store.exportOptions.place)
                Text("信息条添加在照片下方，缺失的拍摄信息留空。").font(.caption).foregroundStyle(.secondary)
            }
            Text("使用照片当前的调整与画质设置。").font(.caption).foregroundStyle(.secondary)
            HStack {Spacer();Button("取消"){store.showExportOptions=false}.keyboardShortcut(.cancelAction);Button("选择位置并导出…"){store.export()}.keyboardShortcut(.defaultAction)}
        }.padding(26).frame(width:440)
    }
}
