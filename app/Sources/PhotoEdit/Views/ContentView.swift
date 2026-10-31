import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(store: store)
            Divider()
            HStack(spacing: 0) {
                if store.showLibrary {
                    LibrarySidebar(store: store).frame(width: 216)
                    Divider()
                }
                if store.photos.isEmpty {
                    WelcomeView(store: store)
                } else {
                    HSplitView {
                        VStack(spacing: 0) {
                            CanvasHeader(store: store)
                            if store.grid { ComparisonGrid(store: store) }
                            else { PhotoCanvas(store: store) }
                            Divider()
                            FilmstripView(store: store).frame(height: 150)
                        }.frame(minWidth: 560)
                        InspectorView(store: store).frame(minWidth: 320, idealWidth: 350, maxWidth: 390)
                    }
                }
            }
            Divider()
            WorkspaceStatus(store: store)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .background(Color(white: 0.18))
        .tint(Color(white: 0.8))
        // 裁切页按回车＝点「确定」：SwiftUI 的 default action 在有 ScrollView 的右栏里
        // 经常抢不到，直接接键盘事件最稳。
        .background(ReturnKeyCatcher { event in
            // 确认卡片挂着的时候，回车＝「应用并切换」，Esc＝取消。
            if store.cropSwitchPrompt {
                if event.keyCode == 53 { store.cancelCropSwitch(); return true }
                guard event.keyCode == 36 || event.keyCode == 76 else { return false }
                store.confirmCropSwitch(apply: true)
                return true
            }
            guard store.inspectorTab == "crop", store.cropEditing, !store.controlsBlocked else { return false }
            guard event.keyCode == 36 || event.keyCode == 76 else { return false }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            // 正在打字（输入框、重命名）时回车归输入框，不要抢。
            if let window = event.window, window.firstResponder is NSTextView { return false }
            store.finishCrop()
            return true
        })
        .overlay {
            if store.cropSwitchPrompt { CropSwitchDialog(store: store) }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $store.showExportOptions) { ExportSheet(store: store).preferredColorScheme(.dark) }
        .sheet(isPresented: Binding(get: { store.settingsTab != nil }, set: { if !$0 { store.settingsTab = nil } })) {
            SettingsSheet(store: store)
        }
        .onChange(of: store.overlay) { _, value in if !value.isEmpty && store.analysis == nil { store.loadAnalysis() } }
    }
}

private struct WorkspaceHeader: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @State private var showingReset = false
    @State private var showingHistory = false
    private var resetTitle: String {
        store.targets.count > 1 ? "把所选的 \(store.targets.count) 张照片复原成原图？" : "把这张照片复原成原图？"
    }
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 34, height: 34)
                Text(AppIdentity.name).font(.system(size: 16, weight: .semibold))
                    .fixedSize()
            }
            .frame(width: 188, alignment: .leading)
            Divider().frame(height: 24)
            HStack(spacing: 14) {
                Button { store.showLibrary.toggle() } label: { Label("图集", systemImage: "sidebar.left") }
                    .help("显示或隐藏图集栏")
                Button { store.chooseImport() } label: { Label("添加照片", systemImage: "plus") }
                    .disabled(store.controlsBlocked)
            }
            Spacer(minLength: 16)
            if !store.photos.isEmpty {
                HStack(spacing: 6) {
                    Button { store.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                        .help("撤销上一步（⌘Z）").disabled(!store.canUndo || store.controlsBlocked)
                    Button { store.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                        .help("重做（⇧⌘Z）").disabled(!store.canRedo || store.controlsBlocked)
                    Button { showingHistory.toggle() } label: { Label("历史记录", systemImage: "clock.arrow.circlepath") }
                        .help("查看调整历史")
                        .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                            HistoryPanel(store: store).frame(width: 260, height: 350)
                        }
                    Button { showingReset = true } label: { Label("复原", systemImage: "arrow.counterclockwise") }
                        .help("把照片恢复成导入时的原图").disabled(store.targets.isEmpty || store.controlsBlocked)
                }.labelStyle(.titleAndIcon)
                    .alert(resetTitle, isPresented: $showingReset) {
                        Button("复原原图") { store.resetToOriginal() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("会去掉调色、移除杂物、AI 生成的版本和画质设置，换回导入时的原图。复原后可以用「撤销」找回。")
                    }
                Divider().frame(height: 22)
                Button("导出 \(store.targets.count) 张…") { store.showExportOptions = true }
                    .buttonStyle(.borderedProminent).disabled(store.targets.isEmpty || store.controlsBlocked)
            }
        }.padding(.leading, 14).padding(.trailing, 20).frame(height: 64).background(Color(white: 0.13))
        .buttonStyle(.borderless)
    }
}

private struct CanvasHeader: View {
    @Bindable var store: WorkspaceStore
    @ViewBuilder private func toolButtons(spacing: CGFloat, group: Int = 0) -> some View {
        HStack(spacing: spacing) {
            if group != 2 {
            chip("原图", "circle.lefthalf.filled", store.showOriginal, help: "按 \\ 切换整张原图") { store.toggleOriginal() }
            chip("对比", "rectangle.split.2x1", store.splitCompare && !store.grid,
                 help: store.compareAvailable ? "拖动画面上的分隔线比较原图和调整后" : "请先完成当前工具，再查看对比") { store.toggleCompare() }
                .disabled(!store.compareAvailable)
            Divider().frame(height: 18)
            chip("画质", "wand.and.stars", store.inspectorTab == "quality", help: "降噪与放大") { pick("quality") }
                .disabled(store.current == nil || store.controlsBlocked)
            chip("选区", "lasso", store.inspectorTab == "selection", help: "画选区，可以多笔加减") { pick("selection") }
                .disabled(store.current == nil || store.controlsBlocked && store.inspectorTab != "selection")
            }
            if group != 1 {
            chip("移除", "bandage", store.inspectorTab == "repair", help: "移除杂物") { pick("repair") }
                .disabled(store.current == nil || store.controlsBlocked && store.inspectorTab != "repair")
            chip("裁切", "crop.rotate", store.inspectorTab == "crop", help: "裁切、旋转、翻转和自由旋转") { pick("crop") }
                .disabled(store.current == nil || store.controlsBlocked && store.inspectorTab != "crop")
            chip("抠图", "scissors", store.inspectorTab == "cutout", help: "抠出照片中的主体，另存透明 PNG") { pick("cutout") }
                .disabled(store.current == nil || store.controlsBlocked)
            }
        }.fixedSize()
    }

    /// 工具按钮：选中的那个整块高亮成浅色胶囊，一眼能看出现在在哪一页。
    private func chip(_ title: String, _ icon: String, _ isOn: Bool, help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.callout.weight(isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? Color(white: 0.12) : Color.white.opacity(0.82))
            .padding(.horizontal, 10).frame(height: 26)
            .background(isOn ? Color.white.opacity(0.92) : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func pick(_ name: String) {
        if name == "selection" { store.selectionForAI = false }
        store.inspectorTab = store.inspectorTab == name ? store.lastMainTab : name
    }

    private var aiOff: Bool {
        store.current == nil || (store.controlsBlocked && store.inspectorTab != "aiedit")
    }

    /// AI 改图不是普通工具：它要调外部服务、会生成新画面，所以单独做成一个带颜色的小胶囊，
    /// 跟左边那些灰按钮区分开，一眼就能找到。
    private var aiButton: some View {
        let on = store.inspectorTab == "aiedit"
        return Button {
            store.inspectorTab = on ? store.lastMainTab : "aiedit"
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                Text("AI 改图").font(.callout.weight(.semibold))
            }
            .foregroundStyle(on ? AnyShapeStyle(.white)
                                : AnyShapeStyle(Color(red: 0.80, green: 0.70, blue: 1.0)))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                if on {
                    LinearGradient(colors: [Color(red: 0.56, green: 0.29, blue: 0.96),
                                            Color(red: 0.31, green: 0.55, blue: 1.0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } else {
                    Color(red: 0.45, green: 0.30, blue: 0.95).opacity(0.22)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(red: 0.72, green: 0.58, blue: 1.0).opacity(on ? 0 : 0.55),
                                      lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(aiOff ? 0.4 : 1)
        .disabled(aiOff)
        .help("AI 改图：换背景、加东西、去掉大物体，会生成新画面")
    }
    var body: some View {
        // 工具按钮始终带文字；窗口窄时先藏照片名，再把按钮间距收紧，不退化成看不懂的纯图标。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(minLength: 12); toolButtons(spacing: 8); Divider().frame(height: 18); aiButton; gridPicker }.frame(height: 54)
            HStack(spacing: 10) { Spacer(minLength: 0); toolButtons(spacing: 6); Divider().frame(height: 18); aiButton; gridPicker }.frame(height: 54)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) { toolButtons(spacing: 4, group: 1); Spacer(minLength: 0); gridPicker }
                HStack(spacing: 4) { toolButtons(spacing: 4, group: 2); Spacer(minLength: 0); aiButton }
            }.padding(.vertical, 8)
        }.padding(.horizontal, 18)
    }

    @ViewBuilder private var title: some View {
        HStack(spacing: 8) {
            Text(store.grid ? "整批预览" : store.current?.imported.name ?? "").font(.callout.weight(.medium)).lineLimit(1)
            if !store.grid, let photo = store.current { Text(photo.lookName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.fixedSize()
    }

    private var gridPicker: some View {
        Picker("预览方式", selection: $store.grid) {
            Image(systemName: "rectangle").tag(false)
            Image(systemName: "square.grid.2x2").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 72).disabled(store.inspectorTab == "repair")
            .onChange(of: store.grid) { _, value in if value { store.refreshGrid() } }
            .help("单张／整批预览")
    }
}

private struct WorkspaceStatus: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var updates: UpdateChecker
    var body: some View {
        HStack(spacing: 10) {
            Button { AboutState.shared.tab = .intro; openWindow(id: "about") } label: {
                Label("关于", systemImage: "info.circle")
                    .font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).help("关于随心 AI 修图")
            switch updates.phase {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 55).controlSize(.mini)
                Text("\(Int(fraction * 100))%").font(.callout).monospacedDigit()
            case .installing:
                ProgressView().controlSize(.mini)
                Text("正在安装").font(.callout)
            case .idle:
                if let release = updates.available {
                    Button { updates.offerAvailable() } label: {
                        Label("新版本 \(release.version)", systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).foregroundStyle(.cyan)
                } else {
                    Button("v\(AppIdentity.version)") { AboutState.shared.tab = .changelog; openWindow(id: "about") }
                        .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 7)).help("查看更新记录")
                }
            }
            Divider().frame(height: 16)
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
        }.padding(.horizontal, 16).frame(height: 44).background(Color(white: 0.12))
    }
}

private struct WelcomeView: View {
    @Bindable var store: WorkspaceStore

    /// 首页只讲一件事：这是一款「对话式修图」软件。三块内容是它的三条路，
    /// 不是三个并列的功能——所以标题给对话式修图，预设和 AI 改图跟在下面当说明。
    private struct Path: Identifiable {
        let id: String, icon: String, tint: Color, title: String, text: String, tag: String
    }

    private let paths = [
        Path(id: "chat", icon: "text.bubble.fill", tint: Color(red: 0.46, green: 0.70, blue: 1.0),
             title: "对话式修图",
             text: "说一句「画面暖一点，人脸亮一点」，AI 看完照片给出调色方案。参数能接着改，能对比，也能一键撤销。",
             tag: "需要配置支持看图的 AI 服务"),
        Path(id: "preset", icon: "circle.lefthalf.filled", tint: Color(red: 0.96, green: 0.77, blue: 0.45),
             title: "预设调色",
             text: "常规与风格化两组共 34 款，一键套上，再拉强度、光线和颜色。这些在本机算，不用 AI 账号。",
             tag: "常规 · 风格化"),
        Path(id: "ai", icon: "sparkles", tint: Color(red: 0.75, green: 0.62, blue: 1.0),
             title: "AI 改图",
             text: "换背景、加东西、只改一块选区，按你的要求重新画一版。结果存成新版本，原图不动。",
             tag: "需要配置出图服务"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 78, height: 78)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 5)
            VStack(spacing: 8) {
                Text(AppIdentity.name).font(.system(size: 36, weight: .semibold)).padding(.top, 20)
                Text("对话式修图").font(.system(size: 17)).foregroundStyle(Color.white.opacity(0.6))
            }
            Button("导入照片或文件夹") { store.chooseImport() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .disabled(store.importing)
                .padding(.top, 30)
            HStack(alignment: .top, spacing: 18) {
                ForEach(paths) { card($0) }
            }.padding(.top, 46)
            Spacer(minLength: 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) {
                RadialGradient(colors: [Color(red: 0.42, green: 0.38, blue: 0.72).opacity(0.22), .clear],
                               center: .init(x: 0.5, y: -0.15), startRadius: 20, endRadius: 520)
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in store.importURLs(urls); return true }
    }

    private func card(_ path: Path) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: path.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(path.tint).frame(width: 30, height: 30)
                    .background(path.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                Text(path.title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text(path.text).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(path.tag).font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.42)).lineLimit(1)
        }
        .padding(17)
        .frame(width: 262, height: 176, alignment: .topLeading)
        .background(Color(white: 0.215), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 1))
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
