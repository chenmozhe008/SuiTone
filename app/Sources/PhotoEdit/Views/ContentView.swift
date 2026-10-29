import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(store: store)
            Divider()
            if store.photos.isEmpty {
                WelcomeView(store: store)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        CanvasHeader(store: store)
                        if store.grid { ComparisonGrid(store: store) }
                        else { PhotoCanvas(store: store) }
                        Divider()
                        FilmstripView(store: store).frame(height: 128)
                    }.frame(minWidth: 560)
                    InspectorView(store: store).frame(minWidth: 320, idealWidth: 350, maxWidth: 390)
                }
            }
            Divider()
            WorkspaceStatus(store: store)
        }
        .frame(minWidth: 1050, minHeight: 720)
        .background(Color(white: 0.18))
        .tint(Color(white: 0.8))
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $store.showExportOptions) { ExportSheet(store: store) }
        .onChange(of: store.overlay) { _, value in if !value.isEmpty && store.analysis == nil { store.loadAnalysis() } }
    }
}

private struct WorkspaceHeader: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.name).font(.system(size: 15, weight: .semibold))
                Text(store.photos.isEmpty ? AppIdentity.englishName : "\(AppIdentity.englishName) · \(store.included.count) 张照片")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { store.chooseImport() } label: { Label("添加照片", systemImage: "plus") }
                .disabled(store.controlsBlocked)
            Spacer(minLength: 16)
            if !store.photos.isEmpty {
                HStack(spacing: 4) {
                    Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("撤销，可退回整批调整").disabled(!store.canUndo || store.controlsBlocked)
                    Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .help("重做").disabled(!store.canRedo || store.controlsBlocked)
                }
                Divider().frame(height: 22)
                if store.inspectorTab == "repair" {
                    Text("修复当前照片").font(.caption).foregroundStyle(.secondary).fixedSize()
                } else {
                Text("应用范围").font(.caption).foregroundStyle(.secondary).fixedSize()
                Picker("应用范围", selection: $store.scope) {
                    Text("整批").tag(AdjustmentScope.all)
                    Text("所选").tag(AdjustmentScope.selected)
                    Text("当前").tag(AdjustmentScope.current)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 172).disabled(store.controlsBlocked)
                }
                Button("导出 \(store.targets.count) 张…") { store.showExportOptions = true }
                    .buttonStyle(.borderedProminent).disabled(store.targets.isEmpty || store.controlsBlocked)
            }
        }.padding(.horizontal, 20).frame(height: 64).background(Color(white: 0.13))
        .buttonStyle(.borderless)
    }
}

private struct CanvasHeader: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        HStack(spacing: 12) {
            Text(store.grid ? "整批预览" : store.current?.imported.name ?? "")
                .font(.callout.weight(.medium)).lineLimit(1)
            if !store.grid, let photo = store.current {
                Text(photo.lookName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $store.splitCompare) { Label("左右对比", systemImage: "rectangle.split.2x1") }
                .toggleStyle(.button).help("拖动画面上的分隔线比较原图和调整后").disabled(store.grid)
            Toggle(isOn: $store.showOriginal) { Label("原图", systemImage: "circle.lefthalf.filled") }
                .toggleStyle(.button).help("按 \\ 切换整张原图")
            Picker("预览方式", selection: $store.grid) {
                Image(systemName: "rectangle").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 72).disabled(store.inspectorTab == "repair")
                .onChange(of: store.grid) { _, value in if value { store.refreshGrid() } }
                .help("单张／整批预览")
        }.padding(.horizontal, 18).frame(height: 54)
    }
}

private struct WorkspaceStatus: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        HStack(spacing: 10) {
            if store.busy || store.rendering || store.batchProgress { ProgressView().controlSize(.mini) }
            Text(store.status).font(.caption).lineLimit(1)
            if store.batchProgress {
                if store.progressTotal > 0 {
                    ProgressView(value: Double(store.progressDone), total: Double(store.progressTotal))
                        .frame(width: 90).controlSize(.mini)
                    Text("\(store.progressDone)/\(store.progressTotal)").font(.caption).monospacedDigit()
                }
                Button("停止") { store.stopBatch() }.font(.caption).buttonStyle(.link)
            }
            Spacer()
            if let path = store.lastExport {
                Button("显示导出") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
                    .font(.caption).buttonStyle(.link)
            }
        }.padding(.horizontal, 16).frame(height: 32).background(Color(white: 0.12))
    }
}

private struct WelcomeView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "photo.stack").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Color(white: 0.6))
            VStack(spacing: 10) {
                Text("照片调色").font(.system(size: 28, weight: .medium))
                Text("导入照片，自动调整光影与色彩。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("导入照片或文件夹…") { store.chooseImport() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.importing)
            HStack(alignment: .top, spacing: 40) {
                feature("sparkles", "自动调整", "逐张优化光影")
                feature("square.stack", "风格与参考", "统一整组色彩")
                feature("text.bubble", "对话调整", "描述需要的变化")
            }.padding(.top, 16)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in store.importURLs(urls); return true }
    }
    private func feature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ComparisonGrid: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 18) {
                ForEach(store.photos) { photo in
                    VStack(alignment: .leading, spacing: 8) {
                        LocalPhoto(path: store.showOriginal ? photo.imported.original : photo.previewPath ?? photo.imported.original)
                            .frame(height: 176).frame(maxWidth: .infinity)
                            .overlay(alignment: .topTrailing) {
                                if !photo.ready { ProgressView().controlSize(.mini).padding(8) }
                            }
                        HStack {
                            Text(photo.imported.name).lineLimit(1)
                            Spacer()
                            if photo.excluded { Image(systemName: "xmark.circle") }
                            else { Text(store.showOriginal ? "原图" : photo.lookName).foregroundStyle(.secondary) }
                        }.font(.caption)
                    }.padding(8)
                        .background(photo.id == store.currentID ? Color(white: 0.25) : Color(white: 0.16))
                        .overlay(Rectangle().stroke(photo.id == store.currentID ? Color(white: 0.6) : .clear, lineWidth: 1))
                        .opacity(photo.excluded ? 0.35 : 1)
                        .onTapGesture(count: 2) { store.activate(photo.id); store.grid = false }
                        .onTapGesture { store.selectPhoto(photo.id, modifiers: NSEvent.modifierFlags) }
                        .accessibilityElement(children: .combine).accessibilityLabel("预览 " + photo.imported.name)
                }
            }.padding(20)
        }.background(Color(white: 0.18))
    }
}
