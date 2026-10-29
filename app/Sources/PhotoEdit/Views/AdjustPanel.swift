import SwiftUI

/// 调整页三层：风格 → 光线／颜色／质感总滑块（点三角展开细项）→ 局部。全部改同一份参数，AI 改完滑块同步移动。
struct AdjustPanel: View {
    @Bindable var store: WorkspaceStore
    @State private var expandedStyles = false
    @State private var expanded: Set<String> = []

    private var styles: [StylePreset] {
        StylePreset.all.filter { $0.creative == (store.styleFamily == "creative") }
    }
    private var availableRegions: [String] {
        RegionNames.all.filter { store.analysis?.regions[$0]?.available == true }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.current == nil {
                    Text("导入照片后可在这里调整。").font(.callout).foregroundStyle(.secondary)
                } else if let region = store.localRegion {
                    localSection(region)
                } else {
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
            HStack {
                Text("风格").font(.headline)
                Spacer()
                if store.styleFamily != "mine" && styles.count > 6 {
                    Button(expandedStyles ? "收起" : "全部 \(styles.count) 款") { expandedStyles.toggle() }
                        .buttonStyle(.link).font(.callout)
                }
            }
            Picker("风格类型", selection: $store.styleFamily) {
                Text("自然").tag("natural")
                Text("出片").tag("creative")
                Text("我的风格").tag("mine")
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: store.styleFamily) { _, _ in expandedStyles = false }
            if store.styleFamily == "mine" { myStyles } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3), spacing: 8) {
                    ForEach(expandedStyles ? styles : Array(styles.prefix(6))) { style in
                        Button { store.applyStyle(style.id) } label: {
                            styleTile(title: style.title, tile: store.styleTiles[style.id], icon: style.icon,
                                      selected: store.current?.lookName == style.title)
                        }.buttonStyle(.plain).help(style.detail + "，应用到" + store.scopeLabel)
                    }
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

    private func styleTile(title: String, tile: String?, icon: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let tile { LocalPhoto(path: tile, fill: true) }
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
            }
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
                Text("局部").font(.headline)
                Spacer()
                Text("或在照片上点选").font(.callout).foregroundStyle(.secondary)
            }
            if store.analysis == nil {
                HStack { ProgressView().controlSize(.small); Text("正在识别画面区域…").font(.callout).foregroundStyle(.secondary) }
            } else if availableRegions.isEmpty {
                Text("这张照片没有识别到可单独调整的区域。").font(.callout).foregroundStyle(.secondary)
            } else {
                regionChips(selected: nil)
            }
        }
    }

    private func regionChips(selected: String?) -> some View {
        HStack(spacing: 8) {
            ForEach(availableRegions, id: \.self) { region in
                Button { store.selectLocalRegion(region) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Self.regionColor[region] ?? .gray).frame(width: 8, height: 8)
                        Text(RegionNames.title(region)).font(.callout)
                        if store.current?.parameters.local[region].map({ !$0.isNeutral }) == true {
                            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 11).padding(.vertical, 6)
                        .background(selected == region ? Color(red: 0.24, green: 0.31, blue: 0.48) : Color(white: 0.22), in: Capsule())
                        .overlay(Capsule().stroke(selected == region ? Color(red: 0.36, green: 0.55, blue: 1) : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain)
            }
        }
    }

    private func localSection(_ region: String) -> some View {
        let name = RegionNames.title(region)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("局部").font(.headline)
                Spacer()
                Button("完成") { store.selectLocalRegion(nil) }.buttonStyle(.borderedProminent)
            }
            regionChips(selected: region)
            Text("只改\(name)，边缘自动过渡。").font(.callout).foregroundStyle(.secondary)
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
                Toggle("显示选区", isOn: Binding(get: { store.overlay == region }, set: { store.overlay = $0 ? region : "" }))
                    .toggleStyle(.button)
            }
        }
    }

    private func localSlider(_ region: String, _ title: String, _ key: WritableKeyPath<LocalAdjustment, Double>,
                             _ range: ClosedRange<Double>, reset: Double = 0, display: ((Double) -> String)? = nil) -> some View {
        let label = RegionNames.title(region) + title
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
        }.dropDestination(for: URL.self) { urls, _ in store.importURLs(urls, reference: true); return true }
    }
}
