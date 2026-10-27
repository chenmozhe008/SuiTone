import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SidebarView(store: store).frame(minWidth: 165, idealWidth: 185, maxWidth: 230)
                VStack(spacing: 0) {
                    ReferenceStrip(store: store)
                    Divider()
                    if store.grid { ComparisonGrid(store: store) }
                    else { PhotoCanvas(store: store) }
                }.frame(minWidth: 440)
                InspectorView(store: store).frame(minWidth: 290, idealWidth: 310, maxWidth: 350)
            }
            Divider()
            HStack(spacing: 10) {
                if store.busy || store.rendering { ProgressView().controlSize(.mini) }
                Text(store.status).font(.caption).lineLimit(1)
                Spacer()
                if let path = store.lastExport {
                    Button("显示导出") { NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:path) }.buttonStyle(.link)
                }
                Text("本地处理").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal,14).frame(height:30).background(Color(white:0.14))
        }
        .frame(minWidth: 1020, minHeight: 660)
        .background(Color(white:0.18))
        .tint(Color(white:0.78))
        .toolbar {
            ToolbarItemGroup(placement:.navigation) {
                Button { store.chooseImport() } label: { Label("导入",systemImage:"plus") }.disabled(store.busy)
                Text(store.current?.imported.name ?? "Photo Edit").font(.headline)
            }
            ToolbarItemGroup {
                Button { store.undo() } label: { Label("撤销",systemImage:"arrow.uturn.backward") }.disabled(!store.canUndo || store.busy)
                Button { store.redo() } label: { Label("重做",systemImage:"arrow.uturn.forward") }.disabled(!store.canRedo || store.busy)
                Toggle(isOn:$store.showOriginal) { Label("原图",systemImage:"circle.lefthalf.filled") }.help("按反斜杠键切换原图")
                Toggle(isOn:$store.grid) { Label("并排",systemImage:"square.grid.3x3") }
                    .onChange(of:store.grid) { _, value in if value { store.refreshGrid() } }
                Button("同步所选") { store.synchronize() }.disabled(store.selected.count<2 || store.busy)
                Button("导出…") { store.showExportOptions = true }.disabled(store.selected.isEmpty || store.busy)
            }
        }
        .alert("操作未完成",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {
            Button("好") { store.error=nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented:$store.showExportOptions) { ExportSheet(store:store) }
    }
}

struct ReferenceStrip: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:"photo.on.rectangle").foregroundStyle(.secondary)
            if store.references.isEmpty {
                VStack(alignment:.leading,spacing:3) {
                    Text("拖入参考图，学出颜色与影调").font(.callout)
                    Text("天对天，水对水；每个结果都能继续调整").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing:8) {
                        ForEach(store.references) { reference in
                            LocalPhoto(path:reference.thumbnail).frame(width:64,height:50)
                                .overlay(alignment:.bottom) {
                                    if let scope=store.referenceScopes[reference.id],scope != "all" {
                                        Text("只学"+RegionNames.title(scope)).font(.caption2).padding(2).background(Color(white:0.15))
                                    }
                                }
                                .help(reference.name)
                                .contextMenu {
                                    Button("参与全部区域") {store.referenceScopes[reference.id]="all"}
                                    ForEach(RegionNames.all,id:\.self) {region in
                                        Button("这张只学"+RegionNames.title(region)) {store.referenceScopes[reference.id]=region}
                                    }
                                    Divider()
                                    Button("移除参考") {store.references.removeAll{$0.id==reference.id}}
                                }
                        }
                    }
                }.frame(height:52)
            }
            Spacer(minLength:0)
            Button { store.chooseImport(reference:true) } label: {Image(systemName:"plus")}.help("添加参考图")
            Picker("参考范围",selection:$store.matchOnly) {
                Text("全部区域").tag("all")
                ForEach(RegionNames.all,id:\.self) { Text("只学"+RegionNames.title($0)).tag($0) }
            }.labelsHidden().frame(width:104)
            Button("反推") {store.match()}.disabled(store.references.isEmpty || store.current==nil || store.busy)
        }
        .padding(.horizontal,16).frame(height:78).background(Color(white:0.16))
        .dropDestination(for:URL.self) {urls,_ in store.importURLs(urls,reference:true);return true}
        .accessibilityElement(children:.contain).accessibilityLabel("参考图区域")
    }
}

struct ComparisonGrid: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:190),spacing:10)],spacing:16) {
                ForEach(store.selected) {photo in
                    VStack(spacing:6) {
                        LocalPhoto(path:store.showOriginal ? photo.imported.original : (photo.previewPath ?? photo.imported.original))
                            .frame(height:170)
                        Text(photo.imported.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(5)
                    .background(photo.id==store.currentID ? Color(white:0.26):Color.clear)
                    .onTapGesture {store.activate(photo.id)}
                }
            }.padding(16)
        }.overlay {if store.selected.isEmpty {Text("选择要并排比较的照片").foregroundStyle(.secondary)}}
    }
}
