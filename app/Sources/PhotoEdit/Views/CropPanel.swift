import AppKit
import SwiftUI

extension WorkspaceStore {
    /// 进入裁切页：把照片现在的裁切范围装进画布上的框。
    func beginCrop() {
        guard let photo = current else { return }
        cropDraft = photo.parameters.crop ?? [0, 0, 1, 1]
        cropEditing = true
        cropAspect = "free"
        if photo.ready { schedulePreview() }
    }

    var cropPreviewing: Bool { inspectorTab == "crop" && cropEditing }

    /// 选比例：在当前框里取一个居中的、这个比例的最大框。原来框得小，换了比例不会突然跳回整张。
    func applyCropAspect(_ ratio: Double?) {
        guard let photo = current else { return }
        if cropAspect == "free" { return }
        cropEditing = true
        var width = Double(photo.imported.width), height = Double(photo.imported.height)
        if Int(photo.parameters.rotation) % 180 == 90 { swap(&width, &height) }
        guard width > 0, height > 0 else { return }
        let ratio = ratio ?? width / height
        // 归一化框的横向/纵向比是 k 时，画出来的实际比例是 k × 原画面比例。
        let k = ratio / (width / height)
        let box = cropDraft ?? [0, 0, 1, 1]
        let cx = box[0] + box[2] / 2, cy = box[1] + box[3] / 2
        var cw = box[2], ch = box[3]
        if k >= 1 { ch = cw / k } else { cw = ch * k }
        if ch > box[3] { ch = box[3]; cw = ch * k }
        if cw > box[2] { cw = box[2]; ch = cw / k }
        cropDraft = CropGeometry.centered([cw, ch], around: [cx, cy])
    }

    /// 转 90°：画面转了，已经框好的范围跟着转，不会白丢。
    func rotateQuarter(_ direction: Int) {
        guard current != nil else { return }
        let clockwise = direction > 0
        cropDraft = CropGeometry.rotated(cropDraft ?? [0, 0, 1, 1], quarter: clockwise ? 1 : -1)
        cropAspect = "free"
        change(direction > 0 ? "顺时针旋转 90°" : "逆时针旋转 90°") { parameters in
            var value = (parameters.rotation + Double(direction * 90)).truncatingRemainder(dividingBy: 360)
            if value < 0 { value += 360 }
            parameters.rotation = value
            if let crop = parameters.crop { parameters.crop = CropGeometry.rotated(crop, quarter: clockwise ? 1 : -1) }
        }
    }

    /// 翻转：已经框好的范围跟着镜像，构图不丢。
    func toggleFlip(_ axis: String) {
        guard current != nil else { return }
        cropDraft = CropGeometry.flipped(cropDraft ?? [0, 0, 1, 1], axis: axis)
        cropAspect = "free"
        let title = axis == "h" ? "水平翻转" : "垂直翻转"
        change(title) { parameters in
            parameters.flip = parameters.flip == axis ? "" : axis
            if let crop = parameters.crop { parameters.crop = CropGeometry.flipped(crop, axis: axis) }
        }
    }

    /// 松手才应用：整段拖动只记一条历史、只重算一次画面。
    func applyAngle(_ angle: Double) {
        let value = CropGeometry.snappedAngle(angle)
        change(abs(value) < 0.01 ? "取消旋转" : String(format: "旋转 %.1f°", -value)) { $0.angle = value }
    }

    func straightenPreview(_ angle: Double) {
        // 拖动拉直滑杆时只改角度，不每一步都记历史。
        beginEditing("旋转画面")
        update { $0.angle = CropGeometry.snappedAngle(angle) }
    }

    func finishStraighten() {
        finishEditing()
    }

    /// 「确定」：把框定的范围写进照片，然后把框收起来——框一直压着画面，
    /// 看起来就像「点了确定什么都没发生」。人仍然留在裁切页，想再裁一次点「重新框选」。
    func finishCrop() {
        commitCrop()
        cropEditing = false
        schedulePreview()
        status = "裁切已应用"
    }

    /// 画布上的框跟已经应用的范围不一样（有还没应用的改动）。
    var cropDirty: Bool {
        guard cropEditing, inspectorTab == "crop", let draft = cropDraft else { return false }
        let full = draft[0] < 0.001 && draft[1] < 0.001 && draft[2] > 0.999 && draft[3] > 0.999
        guard let existing = current?.parameters.crop else { return !full }
        return !zip(draft, existing).allSatisfy { abs($0 - $1) < 0.0005 }
    }

    /// 换照片前把裁切这件事拦住：返回 true 表示已经挂起，调用方别再往下切。
    /// 照 Lightroom 的做法——换照片等于「这一张的裁切到此为止」，所以给两个明确的选择，
    /// 而不是默默套用（会裁错）或者默默丢掉（白框了）。
    @discardableResult
    func requestCropSwitch(to id: String?) -> Bool {
        guard cropDirty, id != currentID else { return false }
        pendingCropSwitchTarget = id
        cropSwitchPrompt = true
        return true
    }

    /// 用户的选择：应用这张的裁切再切过去；或者丢掉改动直接切。
    func confirmCropSwitch(apply: Bool) {
        let target = pendingCropSwitchTarget
        pendingCropSwitchTarget = nil
        cropSwitchPrompt = false
        if apply { commitCrop() }
        cropDraft = nil
        cropEditing = false
        selectedIDs = target.map { Set([$0]) } ?? Set<String>()
        performActivate(target)
        status = apply ? "裁切已应用" : "已放弃裁切"
    }

    func cancelCropSwitch() {
        pendingCropSwitchTarget = nil
        cropSwitchPrompt = false
    }

    /// 离开 AI 改图页：这一轮的选区和临时版本预览都撤掉，回到正常画面。
    /// 留着的话，切到别的页还压着上一轮的青色选区，看着像没退出去。
    func leaveAIEdit() {
        versionPreview = nil
        guard !selectionParts.isEmpty || selectionOverlay != nil else { return }
        clearRepairSelection()
    }

    /// 把框写进参数，画布随即按新构图显示。
    func commitCrop() {
        guard let photo = current, let draft = cropDraft else { return }
        let full = draft[0] < 0.001 && draft[1] < 0.001 && draft[2] > 0.999 && draft[3] > 0.999
        // 框没动过就别再记一条历史：连点「确定」不该把历史堆满。
        let existing = photo.parameters.crop
        if full && existing == nil { return }
        if let existing, !full, zip(draft, existing).allSatisfy({ abs($0 - $1) < 0.0005 }) { return }
        change(full ? "恢复整幅画面" : "裁切画面") { parameters in
            parameters.crop = full ? nil : draft
        }
    }

    func resetGeometry() {
        guard current != nil else { return }
        cropDraft = [0, 0, 1, 1]
        cropEditing = true
        cropAspect = "free"
        change("恢复原始构图") { parameters in
            parameters.rotation = 0; parameters.angle = 0; parameters.flip = ""; parameters.crop = nil
        }
    }

    /// 把当前的裁切旋转固定成新的画面：之后画选区、移除、AI 改图都按新构图，不会错位。
    func bakeGeometry() {
        guard let photo = current, photo.parameters.hasGeometry, !controlsBlocked else { return }
        finishEditing()
        let before = capture([photo])
        busy = true; status = "正在应用裁切与旋转…"
        Task {
            defer { busy = false }
            do {
                struct Baked: Decodable { var id: String; var width: Int; var height: Int; var operation: RemovalOperation }
                let result: Baked = try await engine.request("bake-geometry", body: [
                    "id": photo.assetID, "params": try EngineClient.object(photo.parameters)])
                guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                photos[index].assetID = result.id
                photos[index].operations.append(result.operation)
                photos[index].parameters.rotation = 0
                photos[index].parameters.angle = 0
                photos[index].parameters.flip = ""
                photos[index].parameters.crop = nil
                photos[index].parameters.manualMasks = [:]
                photos[index].previewPath = nil
                photos[index].lookName = "裁切后"
                clearRepairSelection()
                analysis = nil; overlay = ""; styleTiles = [:]
                cropDraft = [0, 0, 1, 1]
                // 已经烘进画面了，没有框可调，收起来。
                cropEditing = false
                recordChange("应用裁切与旋转", before: before)
                status = "裁切与旋转已应用，可以继续画选区了"
                schedulePreview(); loadAnalysis()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// 键盘事件兜底：裁切页按回车应当等于点「确定」。
/// SwiftUI 的 `.keyboardShortcut(.defaultAction)` 在带 ScrollView 的右栏里常常抢不到
/// （按钮不在窗口的 keyEquivalent 链上），所以直接在窗口里监听一次 keyDown。
struct ReturnKeyCatcher: NSViewRepresentable {
    /// 返回 true 表示这个按键已经处理掉，不再往下传。
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.handle = handle
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var handle: ((NSEvent) -> Bool)?
        private var token: Any?

        func install() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let handle = self.handle else { return event }
                return MainActor.assumeIsolated { handle(event) } ? nil : event
            }
        }

        func remove() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }
}

/// 换照片时裁切的确认卡片。系统 confirmationDialog 在暗色底上把次按钮画成暗红字，
/// 跟背景糊在一起看不清；这里自己画一张，应用／放弃／取消三档一眼分得开。
struct CropSwitchDialog: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.cancelCropSwitch() }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "crop.rotate")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(ToolAccent.blue.fill, in: RoundedRectangle(cornerRadius: 7))
                    Text("这张照片的裁切还没应用")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("应用后按框住的范围保存；放弃就保持原来的构图，切过去不会带着这个框。")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("取消") { store.cancelCropSwitch() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.75))
                        .padding(.horizontal, 12).frame(height: 30)
                    Button("放弃裁切") { store.confirmCropSwitch(apply: false) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Color(white: 0.28), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14)))
                    Button("应用并切换") { store.confirmCropSwitch(apply: true) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background(ToolAccent.blue.fill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ToolAccent.blue.border))
                }
            }
            .padding(20)
            .frame(width: 392)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
        }
    }
}

/// 右栏的裁切页：比例、旋转、翻转、拉直，加上一个「确定」把几何定下来。
struct CropPanel: View {
    @Bindable var store: WorkspaceStore
    /// 拖动滑杆时的临时角度：这时不重算画面，松手才应用
    private let aspects: [(String, String, Double?)] = [
        ("free", "自由", nil), ("original", "原始", nil), ("1:1", "1:1", 1), ("4:3", "4:3", 4.0 / 3),
        ("5:4", "5:4", 5.0 / 4), ("3:2", "3:2", 3.0 / 2), ("16:9", "16:9", 16.0 / 9),
        ("9:16", "9:16", 9.0 / 16), ("4:5", "4:5", 4.0 / 5)
    ]

    private var angle: Double {
        let value = store.current?.parameters.angle ?? 0
        return value == 0 ? 0 : -value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("比例") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(aspects, id: \.0) { item in
                            Button {
                                store.cropAspect = item.0
                                store.applyCropAspect(item.2)
                            } label: {
                                Text(item.1).font(.callout.weight(store.cropAspect == item.0 ? .semibold : .regular))
                                    .foregroundStyle(store.cropAspect == item.0 ? Color.white : Color.white.opacity(0.8))
                                    .frame(maxWidth: .infinity).frame(height: 32)
                                    .background(store.cropAspect == item.0 ? AnyShapeStyle(ToolAccent.blue.fill) : AnyShapeStyle(Color(white: 0.24)),
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(store.cropAspect == item.0 ? ToolAccent.blue.border : Color.white.opacity(0.08)))
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("在照片上直接拖出保留范围；框内拖动是移动，四角和四边可以拉动大小。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                section("旋转") {
                    HStack(spacing: 8) {
                        textButton("向左转 90°", icon: "rotate.left") { store.rotateQuarter(-1) }
                        textButton("向右转 90°", icon: "rotate.right") { store.rotateQuarter(1) }
                    }
                    HStack(spacing: 8) {
                        textButton("水平翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") { store.toggleFlip("h") }
                        textButton("垂直翻转", icon: "arrow.up.and.down.righttriangle.up.righttriangle.down") { store.toggleFlip("v") }
                    }
                    Text("已经框好的范围会跟着一起转，不用重新框。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                section("自由旋转") {
                    HStack(spacing: 10) {
                        stepButton("−", help: "逆时针 0.5°") { nudge(-0.5) }
                        StraightenSlider(value: angle, range: -180...180) { value in
                            store.straightenPreview(-value)
                        } onEnd: { _ in
                            store.finishStraighten()
                        } onReset: {
                            store.finishStraighten()
                            store.applyAngle(0)
                        }
                        stepButton("+", help: "顺时针 0.5°") { nudge(0.5) }
                    }
                    HStack {
                        Text("−180°").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(String(format: "%+.1f°", angle))
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(abs(angle) < 0.05 ? Color.secondary : ToolAccent.blue.text)
                        Spacer()
                        Text("+180°").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text("拖动旋转照片，双击滑杆归零；大角度旋转会裁去边缘空白。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if store.cropEditing {
                    Button { store.finishCrop() } label: {
                        Label("确定", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(store.controlsBlocked)
                        .keyboardShortcut(.defaultAction)
                        .help("应用框内的范围，并把框收起来（也可以直接按回车）")
                } else {
                    Button { store.beginCrop() } label: {
                        Label("重新框选", systemImage: "crop").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(store.controlsBlocked)
                        .help("在照片上重新拖一个框；已经应用的裁切不会丢")
                    Text("裁切已应用，框已收起。要再裁一次就点「重新框选」，比例和旋转随时能接着调。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Button("恢复原始构图") { store.resetGeometry() }
                    .buttonStyle(.link).disabled(store.controlsBlocked || !(store.current?.parameters.hasGeometry ?? false))
            }.padding(16)
        }
        .onAppear { store.beginCrop() }
    }

    private func nudge(_ delta: Double) {
        let value = min(180, max(-180, angle + delta))
        store.applyAngle(-value)
    }

    private func textButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color(white: 0.24), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
        }.buttonStyle(.plain).disabled(store.controlsBlocked)
    }

    private func stepButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color(white: 0.24), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08)))
        }.buttonStyle(.plain).disabled(store.controlsBlocked).help(help)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 拉直滑杆：中间一条零刻度，从中心向两侧填充；拖到哪算到哪，双击归零。
private struct StraightenSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    var onReset: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let span = range.upperBound - range.lowerBound
            let ratio = min(1, max(0, (value - range.lowerBound) / span))
            let center = width / 2
            let knobX = width * ratio
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 5)
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 13).position(x: center, y: 11)
                Capsule().fill(ToolAccent.blue.fill)
                    .frame(width: abs(knobX - center), height: 5)
                    .position(x: (knobX + center) / 2, y: 11)
                Circle().fill(.white).frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.4), radius: 2.5, y: 1)
                    .offset(x: min(width - 17, max(0, knobX - 8.5)))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let next = range.lowerBound + min(1, max(0, drag.location.x / width)) * span
                        onChange(next)
                    }
                    .onEnded { drag in
                        let next = range.lowerBound + min(1, max(0, drag.location.x / width)) * span
                        onEnd(next)
                    }
            )
            .onTapGesture(count: 2) { onReset() }
        }.frame(height: 22)
    }
}

/// 画布上的裁切框：外面压暗，里面画三分线，四角和四边都有手柄。
/// 这里只管画，拖拽统一由画布处理（见 PhotoCanvas），避免手势互相抢。
struct CropOverlay: View {
    let size: CGSize
    let box: [Double]
    /// 当前画面（旋转、拉直之后）的像素尺寸，用来显示框出来有多少像素
    var pixels: CGSize?

    var body: some View {
        let w = size.width, h = size.height
        let rect = CGRect(x: box[0] * w, y: box[1] * h, width: box[2] * w, height: box[3] * h)
        ZStack(alignment: .topLeading) {
            // 框外压暗
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))

            Rectangle().path(in: rect).stroke(Color.white.opacity(0.9), lineWidth: 1)

            // 三分线
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.24), lineWidth: 0.7)

            // 四角 L 形托角（Lightroom 那种）
            Path { path in
                let arm = min(26, min(rect.width, rect.height) / 2.6)
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
                    (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                    (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
                    (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
                ]
                for (point, dx, dy) in corners {
                    path.move(to: CGPoint(x: point.x + dx * arm, y: point.y))
                    path.addLine(to: point)
                    path.addLine(to: CGPoint(x: point.x, y: point.y + dy * arm))
                }
            }.stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))

            // 四条边的中间手柄
            Path { path in
                let arm: CGFloat = 10
                path.move(to: CGPoint(x: rect.midX - arm, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX + arm, y: rect.minY))
                path.move(to: CGPoint(x: rect.midX - arm, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.midX + arm, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: rect.midY - arm)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + arm))
                path.move(to: CGPoint(x: rect.maxX, y: rect.midY - arm)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + arm))
            }.stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))

            if let pixels, box[2] > 0.02, box[3] > 0.02 {
                Text("\(Int((pixels.width * box[2]).rounded())) × \(Int((pixels.height * box[3]).rounded()))")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.62), in: Capsule())
                    .fixedSize()
                    .position(x: rect.midX, y: max(12, rect.minY - 14))
            }
        }
        .frame(width: w, height: h)
        .allowsHitTesting(false)
    }
}

/// 裁切拖拽的几何计算：命中哪个手柄、拖到什么位置。都是纯函数，方便测。
enum CropGeometry {
    enum Handle: String {
        case draw, inside, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right
    }

    static func drawn(from start: CGPoint, to end: CGPoint, size: CGSize) -> [Double]? {
        guard size.width > 0, size.height > 0 else { return nil }
        let x0 = min(1, max(0, Double(start.x / size.width)))
        let y0 = min(1, max(0, Double(start.y / size.height)))
        let x1 = min(1, max(0, Double(end.x / size.width)))
        let y1 = min(1, max(0, Double(end.y / size.height)))
        let width = abs(x1 - x0), height = abs(y1 - y0)
        guard width >= 0.005, height >= 0.005 else { return nil }
        return [min(x0, x1), min(y0, y1), width, height]
    }

    /// 按下时落在哪个手柄上：四角 26 pt 以内算角，边 18 pt 以内算边，框内是移动，框外是重新画。
    /// 框正好是整张画面时，框内拖动也当成重新画——否则一进去怎么拖都没反应。
    static func handle(at point: CGPoint, box: [Double], size: CGSize, freeform: Bool) -> Handle {
        let rect = CGRect(x: box[0] * size.width, y: box[1] * size.height,
                          width: box[2] * size.width, height: box[3] * size.height)
        let full = box[0] < 0.002 && box[1] < 0.002 && box[2] > 0.998 && box[3] > 0.998
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        if !full, let corner = corners.min(by: {
            hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y)
        }), hypot(corner.1.x - point.x, corner.1.y - point.y) <= 26 {
            return corner.0
        }
        if rect.contains(point) {
            guard !full else { return .draw }
            if abs(point.x - rect.minX) <= 18 { return .left }
            if abs(point.x - rect.maxX) <= 18 { return .right }
            if abs(point.y - rect.minY) <= 18 { return .top }
            if abs(point.y - rect.maxY) <= 18 { return .bottom }
            return .inside
        }
        // 框外拖动一律重新画；锁了比例时按原来的比例画，不会把比例弄丢。
        return .draw
    }

    /// 一次拖动的结果：起手框 + 起止点 → 新框。
    static func dragged(start: [Double], handle: Handle, from: CGPoint, to: CGPoint,
                        size: CGSize, freeform: Bool) -> [Double] {
        guard size.width > 1, size.height > 1 else { return start }
        if handle == .draw {
            guard let drawn = drawn(from: from, to: to, size: size) else { return start }
            return freeform ? drawn : conform(drawn, ratio: start[2] / start[3])
        }
        let dx = Double((to.x - from.x) / size.width)
        let dy = Double((to.y - from.y) / size.height)
        let minSize = 0.01
        var current = start
        switch handle {
        case .inside:
            current[0] = min(max(0, start[0] + dx), 1 - start[2])
            current[1] = min(max(0, start[1] + dy), 1 - start[3])
        case .topLeft:
            let nx = min(max(0, start[0] + dx), start[0] + start[2] - minSize)
            let ny = min(max(0, start[1] + dy), start[1] + start[3] - minSize)
            current[2] = start[2] + (start[0] - nx); current[3] = start[3] + (start[1] - ny)
            current[0] = nx; current[1] = ny
        case .topRight:
            let nr = max(start[0] + minSize, start[0] + start[2] + dx)
            let ny = min(max(0, start[1] + dy), start[1] + start[3] - minSize)
            current[2] = min(1, nr) - start[0]; current[3] = start[3] + (start[1] - ny); current[1] = ny
        case .bottomLeft:
            let nx = min(max(0, start[0] + dx), start[0] + start[2] - minSize)
            let nb = min(1, start[1] + start[3] + dy)
            current[2] = start[2] + (start[0] - nx); current[3] = nb - start[1]; current[0] = nx
        case .bottomRight:
            current[2] = min(1, start[0] + start[2] + dx) - start[0]
            current[3] = min(1, start[1] + start[3] + dy) - start[1]
        case .top:
            let ny = min(max(0, start[1] + dy), start[1] + start[3] - minSize)
            current[3] = start[3] + (start[1] - ny); current[1] = ny
        case .bottom:
            current[3] = min(1, start[1] + start[3] + dy) - start[1]
        case .left:
            let nx = min(max(0, start[0] + dx), start[0] + start[2] - minSize)
            current[2] = start[2] + (start[0] - nx); current[0] = nx
        case .right:
            current[2] = min(1, start[0] + start[2] + dx) - start[0]
        case .draw:
            return start
        }
        current[2] = max(minSize, min(current[2], 1 - current[0]))
        current[3] = max(minSize, min(current[3], 1 - current[1]))
        if !freeform, handle != .inside, handle != .draw {
            current = locked(current: current, start: start, handle: handle.rawValue)
        }
        return current
    }

    static func locked(current: [Double], start: [Double], handle: String) -> [Double] {
        let ratio = start[2] / start[3]
        var width = current[2], height = current[3]
        let horizontal = handle == "left" || handle == "right"
        let vertical = handle == "top" || handle == "bottom"
        if horizontal { height = width / ratio }
        else if vertical { width = height * ratio }
        else if abs(width - start[2]) >= abs((height - start[3]) * ratio) { height = width / ratio }
        else { width = height * ratio }
        let right = start[0] + start[2], bottom = start[1] + start[3]
        let leftSide = handle.lowercased().contains("left"), topSide = handle.lowercased().contains("top")
        let maxW = vertical ? min(2 * (start[0] + start[2] / 2), 2 * (1 - start[0] - start[2] / 2)) : (leftSide ? right : 1 - start[0])
        let maxH = horizontal ? min(2 * (start[1] + start[3] / 2), 2 * (1 - start[1] - start[3] / 2)) : (topSide ? bottom : 1 - start[1])
        width = max(0.08, min(width, maxW, maxH * ratio)); height = width / ratio
        let x = vertical ? start[0] + (start[2] - width) / 2 : (leftSide ? right - width : start[0])
        let y = horizontal ? start[1] + (start[3] - height) / 2 : (topSide ? bottom - height : start[1])
        return [x, y, width, height]
    }

    /// 换比例时在现有框里居中放一个新框，尽量不缩回整张。
    static func centered(_ size: [Double], around center: [Double]) -> [Double] {
        let w = min(1, max(0.01, size[0])), h = min(1, max(0.01, size[1]))
        let x = min(1 - w, max(0, center[0] - w / 2))
        let y = min(1 - h, max(0, center[1] - h / 2))
        return [x, y, w, h]
    }

    /// 按固定比例改一个框的形状（锁比例时重新画框用），保持原来的中心。
    static func conform(_ box: [Double], ratio: Double) -> [Double] {
        guard ratio > 0.0001 else { return box }
        let cx = box[0] + box[2] / 2, cy = box[1] + box[3] / 2
        var w = box[2], h = w / ratio
        if h > 1 { h = 1; w = h * ratio }
        if w > 1 { w = 1; h = w / ratio }
        return [min(1 - w, max(0, cx - w / 2)), min(1 - h, max(0, cy - h / 2)), w, h]
    }

    /// 转 90°：框跟着画面一起转，转回来的区域一样。
    static func rotated(_ box: [Double], quarter: Int) -> [Double] {
        var value = box
        let steps = ((quarter % 4) + 4) % 4
        for _ in 0..<steps {
            value = [1 - (value[1] + value[3]), value[0], value[3], value[2]]
        }
        return value
    }

    /// 镜像：框跟着一起翻。
    static func flipped(_ box: [Double], axis: String) -> [Double] {
        if axis == "h" { return [1 - (box[0] + box[2]), box[1], box[2], box[3]] }
        return [box[0], 1 - (box[1] + box[3]), box[2], box[3]]
    }

    /// 0.5° 以内吸附到 0，避免「看起来正了其实还差 0.2°」。
    static func snappedAngle(_ angle: Double) -> Double {
        abs(angle) < 0.3 ? 0 : (angle * 10).rounded() / 10
    }
}
