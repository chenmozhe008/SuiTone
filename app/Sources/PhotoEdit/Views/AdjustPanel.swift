import SwiftUI

/// 调整页三层：风格 → 光线／颜色／质感总滑块（点三角展开细项）→ 局部。全部改同一份参数，AI 改完滑块同步移动。
struct AdjustPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var expandedStyles = false
    @State private var expanded: Set<String> = []

    private var styles: [StylePreset] {
        store.styleOrder(for: store.styleFamily)
    }
    private var availableRegions: [String] {
        RegionNames.all.filter { store.analysis?.regions[$0]?.available == true }
            + (store.current?.parameters.manualMasks.keys.sorted() ?? [])
    }

    private func regionTitle(_ key: String) -> String {
        guard key.hasPrefix("selection-"), let keys = store.current?.parameters.manualMasks.keys.sorted(),
              let index = keys.firstIndex(of: key) else { return RegionNames.title(key) }
        return "选区 \(index + 1)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.current == nil {
                    Text("导入照片后可在这里调整。").font(.callout).foregroundStyle(.secondary)
                } else if let region = store.localRegion {
                    localSection(region)
                } else {
                    if store.targets.count > 1, let photo = store.current {
                        Text("已选择 \(store.targets.count) 张照片。风格预览以第一张「\(photo.imported.name)」为例，调整作用于所选照片。")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    }
                    styleSection
                    group("light", "光线", master: \.light, auto: true) {
                        slider("曝光", \.exposure, -3...3, reset: 0) { String(format: "%+.1f", $0) }
                        slider("对比", \.contrast, 0...2, reset: 0) { String(format: "%.0f", $0 * 100) }
                        slider("高光", \.highlights, -1...1, reset: 0)
                        slider("阴影", \.shadows, -1...1, reset: 0)
                        slider("白色", \.whites, -1...1, reset: 0)
                        slider("黑色", \.blacks, -1...1, reset: 0)
                    }
                    group("color", "颜色", master: \.vibrance, auto: true) {
                        slider("色温", \.temperature, -1...1, reset: 0)
                        slider("色调", \.tint, -1...1, reset: 0)
                        slider("饱和", \.saturation, 0...2, reset: 1) { String(format: "%+.0f", ($0 - 1) * 100) }
                    }
                    group("texture", "质感", master: \.texture, auto: false, detail: "暗角、柔光、颗粒") {
                        slider("去雾", \.dehazeAmt, 0...1, reset: 0) { String(format: "%.0f", $0 * 100) }
                        slider("褪黑", \.fade, 0...1, reset: 0) { String(format: "%.0f", $0 * 100) }
                    }
                    regionSection
                    ReferencePanel(store: store)
                }
            }.padding(16).disabled(store.controlsBlocked)
        }
    }

    // MARK: 风格

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("风格").font(.headline)
            Picker("风格类型", selection: $store.styleFamily) {
                Text("轻微调整").tag("natural")
                Text("风格化调整").tag("creative")
                Text("我的风格").tag("mine")
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: store.styleFamily) { _, family in
                    expandedStyles = false
                    // 这一组首屏还没算过就先算，别等展开才发现是空的。
                    store.loadStyleTiles()
                    store.ensureStyleTiles(for: family)
                }
            if store.styleFamily == "mine" { myStyles } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3), spacing: 8) {
                    ForEach(expandedStyles ? styles : Array(styles.prefix(6))) { style in
                        Button { store.applyStyle(style.id) } label: {
                            styleTile(title: style.title, tile: store.styleTiles[style.id], icon: "camera.filters",
                                      selected: store.current?.lookName == style.title,
                                      loading: store.styleTiles[style.id] == nil)
                        }.buttonStyle(.plain).help(style.detail + "，应用到" + store.scopeLabel)
                    }
                }
                // 放在缩略图正下方：看完前几款，眼睛自然落到这里。
                if styles.count > 6 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { expandedStyles.toggle() }
                        if expandedStyles { store.ensureStyleTiles(for: store.styleFamily) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(expandedStyles ? "收起" : "展开全部 \(styles.count) 款")
                            Image(systemName: expandedStyles ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                        }.font(.callout.weight(.semibold)).foregroundStyle(Color(red: 0.62, green: 0.86, blue: 1))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Color(red: 0.17, green: 0.27, blue: 0.34), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.35, green: 0.61, blue: 0.73).opacity(0.55)))
                    }.buttonStyle(.plain)
                }
            }
            slider("强度", \.effectStrength, 0...1, reset: 1) { String(format: "%.0f", $0 * 100) }
        }
    }

    private var myStyles: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.myStyles.isEmpty {
                Text("把满意的调整存下来，以后一键套用。").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3), spacing: 8) {
                    ForEach(store.myStyles) { style in
                        Button { store.applyMyStyle(style) } label: {
                            styleTile(title: style.name, tile: nil, icon: "star", selected: store.current?.lookName == style.name)
                        }.buttonStyle(.plain).help("应用到" + store.scopeLabel)
                            .contextMenu { Button("删除这个风格") { store.myStyles.removeAll { $0.id == style.id } } }
                    }
                }
            }
            Button("存为我的风格", systemImage: "plus") { store.saveMyStyle() }
        }
    }

    private func styleTile(title: String, tile: String?, icon: String, selected: Bool,
                           loading: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let tile { LocalPhoto(path: tile, fill: true) }
                else if loading {
                    // 还在算：给个明确的占位，而不是一张会突然被替换的图标。
                    ZStack {
                        Rectangle().fill(Color(white: 0.13))
                        ProgressView().controlSize(.mini).scaleEffect(0.72)
                    }
                }
                else { Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(height: 58).frame(maxWidth: .infinity).background(Color(white: 0.11))
            Text(title).font(.callout).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 6)
        }.background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color(white: 0.9) : .clear, lineWidth: 2))
    }

    // MARK: 光线／颜色／质感

    private func group<Content: View>(_ key: String, _ title: String, master: WritableKeyPath<AdjustmentParameters, Double>,
                                      auto: Bool, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        let open = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    if open { expanded.remove(key) } else { expanded.insert(key) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(title).font(.headline)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                if auto { Button("自动") { store.autoAdjust(key) }.controlSize(.small) }
            }
            slider("整体", master, key == "texture" ? 0...1 : -1...1, reset: 0) {
                key == "texture" ? String(format: "%.0f", $0 * 100) : String(format: "%+.0f", $0 * 100)
            }.accessibilityLabel(title + "整体")
            if open { VStack(spacing: 10) { content() }.padding(.leading, 14) }
        }.padding(12).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private func slider(_ title: String, _ key: WritableKeyPath<AdjustmentParameters, Double>, _ range: ClosedRange<Double>,
                        reset: Double, display: ((Double) -> String)? = nil) -> some View {
        ValueSlider(title: title, value: Binding(get: { store.current?.parameters[keyPath: key] ?? reset }, set: { value in
            store.beginEditing(title); store.update { $0[keyPath: key] = value }
        }), range: range, reset: reset, display: display ?? { String(format: "%+.0f", $0 * 100) }, onEnd: store.finishEditing)
    }

    // MARK: 局部

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("局部调整").font(.headline)
                Spacer()
            }
            .task(id: store.current?.assetID) {
                // 导入后 current 可能还没 ready，activate 时拿不到分析；面板出现时补一次。
                if store.analysis == nil { store.loadAnalysis() }
            }
            if let error = store.analysisError, store.analysis == nil {
                Text("区域识别未完成：\(error)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("重新识别") { store.loadAnalysis() }
            } else if store.analysis == nil && availableRegions.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("正在识别画面区域…").font(.callout).foregroundStyle(.secondary) }
            } else if availableRegions.isEmpty {
                Text("这张照片没有识别到可单独调整的区域。").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("自动识别区域和手动选区，点击后单独调整；也可以在照片上点选。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                regionChips(selected: nil)
            }
        }
    }

    private func regionChips(selected: String?) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(availableRegions, id: \.self) { region in
                Button { store.selectLocalRegion(region) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Self.regionColor[region] ?? .gray).frame(width: 8, height: 8)
                        Text(regionTitle(region)).font(.callout)
                        if store.current?.parameters.local[region].map({ !$0.isNeutral }) == true {
                            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == region ? Color(red: 0.24, green: 0.31, blue: 0.48) : Color(white: 0.22), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected == region ? Color(red: 0.36, green: 0.55, blue: 1) : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain)
            }
        }
    }

    private func localSection(_ region: String) -> some View {
        let name = regionTitle(region)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("局部").font(.headline)
                Spacer()
                Button("完成") { store.selectLocalRegion(nil) }.buttonStyle(.borderedProminent)
            }
            regionChips(selected: region)
            HStack {
                Text("只改\(name)，边缘自动过渡。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.showLocalOverlay(store.overlay == region ? nil : region)
                } label: {
                    Label(store.overlay == region ? "隐藏选区" : "显示选区",
                          systemImage: store.overlay == region ? "eye.slash" : "eye")
                }.buttonStyle(.bordered).controlSize(.regular)
                    .help("显示或隐藏照片上的选区遮罩")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("光线").font(.headline)
                localSlider(region, "曝光", \.exposure, -1...1)
                localSlider(region, "对比", \.contrast, -1...1)
                localSlider(region, "高光", \.highlights, -1...1)
            }.padding(12).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                Text("颜色").font(.headline)
                localSlider(region, "色温", \.temperature, -1...1)
                localSlider(region, "饱和", \.saturation, -1...1)
                localSlider(region, "色相", \.hue, -180...180) { String(format: "%+.0f°", $0) }
            }.padding(12).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 10))
            localSlider(region, "羽化", \.feather, 0...1, reset: 0.5) { String(format: "%.0f", $0 * 100) }
            HStack {
                Button("重置\(name)") { store.change("重置" + name) { $0.local[region] = nil } }
                    .disabled(store.current?.parameters.local[region] == nil)
                if region.hasPrefix("selection-") {
                    Button("编辑选区") { store.editSavedSelection(region) }
                    Button("删除选区") {
                        store.change("删除" + name) { $0.local[region] = nil; $0.manualMasks[region] = nil }
                        store.selectLocalRegion(nil)
                    }
                }
            }
        }
    }

    private func localSlider(_ region: String, _ title: String, _ key: WritableKeyPath<LocalAdjustment, Double>,
                             _ range: ClosedRange<Double>, reset: Double = 0, display: ((Double) -> String)? = nil) -> some View {
        let label = regionTitle(region) + title
        return ValueSlider(title: title, value: Binding(get: {
            store.current?.parameters.local[region]?[keyPath: key] ?? (key == \LocalAdjustment.feather ? 0.5 : 0)
        }, set: { value in
            store.beginEditing(label)
            store.update { $0.local[region, default: LocalAdjustment()][keyPath: key] = value }
        }), range: range, reset: reset, display: display ?? { String(format: "%+.0f", $0 * 100) }, onEnd: store.finishEditing)
    }

    static let regionColor: [String: Color] = [
        "sky": Color(red: 0.43, green: 0.55, blue: 1), "water": Color(red: 0.16, green: 0.75, blue: 0.86),
        "person": Color(red: 0.9, green: 0.39, blue: 0.55), "land": Color(red: 0.86, green: 0.63, blue: 0.24)]
}

/// 参考图：拖进来或点 ＋ 添加，学习颜色与影调；对话里说“照参考图调”也走这里。
struct ReferencePanel: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("参考图").font(.headline)
                Spacer()
                Button { store.chooseImport(reference: true) } label: { Image(systemName: "plus") }.help("添加参考图")
            }
            if store.references.isEmpty {
                Text("拖入一张喜欢的照片，学习它的颜色与影调。").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.references) { reference in
                            VStack(spacing: 3) {
                                LocalPhoto(path: reference.thumbnail, fill: true).frame(width: 76, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(alignment: .topTrailing) { RemoveReferenceButton(store: store, id: reference.id) }
                                Text(store.referenceScopes[reference.id].map { $0 == "all" ? "全部区域" : "只学" + RegionNames.title($0) } ?? "全部区域")
                                    .font(.caption).foregroundStyle(.secondary)
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
                    Button("匹配\(store.scopeLabel)") { store.match() }.disabled(store.targets.isEmpty)
                }
                Text("只学颜色与影调，光线方向不变。").font(.callout).foregroundStyle(.secondary)
            }
            if let photo = store.current, photo.parameters.hasReferenceMatch {
                ValueSlider(title: "强度", value: Binding(get: { store.current?.parameters.matchStrength ?? 1 }, set: { value in
                    store.beginEditing("参考强度"); store.update { $0.matchStrength = value }
                }), range: 0...1, reset: 0.7, display: { String(format: "%.0f", $0 * 100) }, onEnd: store.finishEditing)
                if photo.lookName == "参考匹配", let advice = photo.notes.first(where: { $0.contains("强度") }) {
                    Text(advice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.dropDestination(for: URL.self) { urls, _ in store.importURLs(urls, reference: true); return true }
    }
}

/// 参考图缩略图右上角的移除按钮。
struct RemoveReferenceButton: View {
    @Bindable var store: WorkspaceStore
    let id: String
    var body: some View {
        Button {
            store.references.removeAll { $0.id == id }; store.referenceScopes[id] = nil
        } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .black.opacity(0.6))
        }.buttonStyle(.plain).padding(3).help("移除这张参考图")
    }
}
