import SwiftUI

struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            Picker("工作方式", selection: $store.inspectorTab) {
                Text("调色").tag("start")
                Text("修复").tag("repair")
                Text("AI 对话").tag("chat")
            }.pickerStyle(.segmented).labelsHidden().padding(16)
            Divider()
            if store.inspectorTab == "chat" { AssistantPanel(store: store) }
            else if store.inspectorTab == "repair" { RepairPanel(store: store) }
            else { QuickAdjustmentsView(store: store) }
        }.background(Color(white: 0.15))
            .onChange(of: store.inspectorTab) { _, tab in
                store.cancelRepairPreview()
                store.repairEnabled = tab == "repair"
                store.overlay = ""; store.showOriginal = false
                if tab == "repair" { store.grid = false }
                if tab == "start" { store.loadStyleTiles() }
            }
    }
}

private struct QuickAdjustmentsView: View {
    @Bindable var store: WorkspaceStore
    @State private var showMasks = false
    @State private var expandedStyles = false
    private var styles: [StylePreset] {
        StylePreset.all.filter { $0.creative == (store.styleFamily == "creative") }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                styleSection
                Divider()
                ReferencePanel(store: store)
                Divider()
                if let photo = store.current {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("微调当前照片").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("快照") { store.snapshot() }.font(.caption)
                        }
                        quickSlider("曝光", key: \.exposure, range: -3...3)
                        quickSlider("色温", key: \.temperature, range: -1...1)
                        quickSlider("饱和", key: \.saturation, range: 0...2)
                        HStack {
                            Button("同步到\(store.scope.title)") { store.synchronize() }
                                .disabled(store.targets.filter { $0.id != photo.id }.isEmpty)
                            Spacer()
                            Button("对话调整", systemImage: "text.bubble") { store.inspectorTab = "chat" }
                        }.font(.caption)
                    }
                    QualityPanel(store: store)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                            Text("调整记录").fontWeight(.medium)
                            Spacer()
                            Text(photo.lookName).foregroundStyle(.secondary)
                        }.font(.caption)
                        if photo.notes.isEmpty { Text("暂无调整说明。").font(.caption).foregroundStyle(.secondary) }
                        else {
                            ForEach(Array(photo.notes.prefix(4).enumerated()), id: \.offset) { _, note in
                                Text(note).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                            }
                            if photo.notes.count > 4 {
                                DisclosureGroup("全部 \(photo.notes.count) 项") {
                                    ForEach(Array(photo.notes.dropFirst(4).enumerated()), id: \.offset) { _, note in
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.font(.caption)
                            }
                        }
                        DisclosureGroup("查看选区", isExpanded: $showMasks) {
                            Picker("选区", selection: $store.overlay) {
                                Text("关闭").tag("")
                                ForEach(RegionNames.all + ["skin"], id: \.self) { Text(RegionNames.title($0)).tag($0) }
                            }.padding(.top, 5)
                            if let analysis = store.analysis {
                                ForEach(RegionNames.all, id: \.self) { name in
                                    if let region = analysis.regions[name] {
                                        HStack {
                                            Text(RegionNames.title(name))
                                            Spacer()
                                            Text(region.available ? String(format: "%.0f%% · 置信 %.0f%%", region.area * 100, region.confidence * 100) : "不足／不确定")
                                        }.font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            } else { ProgressView().controlSize(.small) }
                        }.font(.caption)
                            .onChange(of: showMasks) { _, expanded in if expanded { store.loadAnalysis() } else { store.overlay = "" } }
                    }.padding(12).background(Color(white: 0.12))
                    DisclosureGroup("精细调整") {
                        DetailedAdjustmentsView(store: store).padding(.top, 14)
                    }.font(.callout)
                }
            }.padding(16).disabled(store.controlsBlocked)
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("风格").font(.headline)
                Spacer()
                Text(store.scopeLabel).font(.caption).foregroundStyle(.secondary)
            }
            Picker("风格类型",selection:$store.styleFamily) {
                Text("自然微调").tag("natural")
                Text("创作风格").tag("creative")
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: store.styleFamily) { _, _ in expandedStyles = false }
            quickSlider("效果强度", key: \.effectStrength, range: 0...1)
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 8) {
                ForEach(expandedStyles ? styles : Array(styles.prefix(4))) { style in
                    Button { store.applyStyle(style.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let tile=store.styleTiles[style.id] {
                                LocalPhoto(path:tile).frame(height:76).frame(maxWidth:.infinity).background(Color(white:0.1))
                            }
                            HStack {
                                if store.styleTiles[style.id]==nil {Image(systemName: style.icon).font(.callout).foregroundStyle(.secondary)}
                                Text(style.title).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            Text(style.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .background(Color(white: store.current?.lookName == style.title ? 0.28 : 0.2))
                            .overlay(Rectangle().stroke(Color(white: store.current?.lookName == style.title ? 0.5 : 0.26), lineWidth: 1))
                    }.buttonStyle(.plain).help("应用到" + store.scopeLabel)
                }
            }
            Button {
                expandedStyles.toggle()
            } label: {
                HStack {
                    Text(expandedStyles ? "收起风格" : "全部 \(styles.count) 款风格")
                    Spacer()
                    Image(systemName: expandedStyles ? "chevron.up" : "chevron.down")
                }.font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
    }

    private func quickSlider(_ title: String, key: WritableKeyPath<AdjustmentParameters, Double>, range: ClosedRange<Double>) -> some View {
        ValueSlider(title: title, value: Binding(get: { store.current?.parameters[keyPath: key] ?? range.lowerBound }, set: { value in
            store.beginEditing(title); store.update { $0[keyPath: key] = value }
        }), range: range, onEnd: store.finishEditing)
    }
}

private struct QualityPanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("画质").font(.subheadline.weight(.semibold))
                Spacer()
                Text(store.scopeLabel).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("降噪", isOn: Binding(get: { store.current?.quality.denoise ?? false }, set: { value in
                store.applyQuality(denoise: value)
            }))
            Picker("分辨率", selection: Binding(get: { store.current?.quality.scale ?? 1 }, set: { value in
                store.applyQuality(scale: value)
            })) {
                Text("原尺寸").tag(1)
                Text("放大 2 倍").tag(2)
                Text("放大 4 倍").tag(4)
            }
            Text("调整后可预览、对比和撤销。放大首次生成较慢。").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

private struct ReferencePanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("参考匹配").font(.subheadline.weight(.semibold))
                Spacer()
                Button { store.chooseImport(reference: true) } label: { Image(systemName: "plus") }.help("添加参考图")
            }
            if store.references.isEmpty {
                Button { store.chooseImport(reference: true) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle").font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("添加参考图").font(.callout)
                            Text("匹配色彩与影调").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity).background(Color(white: 0.11))
                }.buttonStyle(.plain)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.references) { reference in
                            VStack(spacing: 3) {
                                LocalPhoto(path: reference.thumbnail).frame(width: 76, height: 52)
                                Text(store.referenceScopes[reference.id].map { $0 == "all" ? "全部区域" : "只学" + RegionNames.title($0) } ?? "全部区域")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }.help(reference.name).contextMenu {
                                Button("参与全部区域") { store.referenceScopes[reference.id] = "all" }
                                ForEach(RegionNames.all, id: \.self) { region in
                                    Button("这张只学" + RegionNames.title(region)) { store.referenceScopes[reference.id] = region }
                                }
                                Divider()
                                Button("移除参考") { store.references.removeAll { $0.id == reference.id } }
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                HStack {
                    Picker("学习范围", selection: $store.matchOnly) {
                        Text("所有区域").tag("all")
                        ForEach(RegionNames.all, id: \.self) { Text("只学" + RegionNames.title($0)).tag($0) }
                    }.labelsHidden()
                    Button("匹配\(store.scope.title)") { store.match() }.disabled(store.targets.isEmpty)
                }.controlSize(.small)
                Text("只学颜色与影调；光线方向不会改变。缺少共同区域的部分保持原样。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.dropDestination(for: URL.self) { urls, _ in store.importURLs(urls, reference: true); return true }
    }
}
