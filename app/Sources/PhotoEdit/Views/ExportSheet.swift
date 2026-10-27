import SwiftUI

struct ExportSheet:View {
    @Bindable var store:WorkspaceStore
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("导出 \(store.selected.count) 张照片").font(.title2)
            Text("保持完整画幅与原比例，在目标位置新建版本文件夹。").font(.callout).foregroundStyle(.secondary)
            Toggle("添加出片信息条",isOn:$store.exportOptions.infoBar)
            if store.exportOptions.infoBar {
                TextField("地点",text:$store.exportOptions.place)
                Text("信息条会增加画布高度，照片区域不裁切。EXIF 缺失项留空。").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("降噪",isOn:$store.exportOptions.denoise)
            Picker("放大",selection:$store.exportOptions.scale) {
                Text("原尺寸").tag(1);Text("2 倍").tag(2);Text("4 倍（救急）").tag(4)
            }
            Toggle("同时导出全局底色 LUT",isOn:$store.exportOptions.lut)
            if store.exportOptions.lut {
                Text("LUT 包含全局曝光、对比与饱和。水／天／土地／人物分区、去雾、自动黑白点和修补无法完整装进 LUT；在达芬奇里需另建区域节点。").font(.caption).foregroundStyle(.secondary)
            }
            Text("全尺寸修补和放大比预览慢，导出期间请保持 App 打开。").font(.caption).foregroundStyle(.secondary)
            HStack {Spacer();Button("取消"){store.showExportOptions=false}.keyboardShortcut(.cancelAction);Button("选择位置并导出…"){store.export()}.keyboardShortcut(.defaultAction)}
        }.padding(26).frame(width:440)
    }
}
