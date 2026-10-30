import AppKit
import SwiftUI

extension WorkspaceStore {
    /// 进入裁切页：把照片现在的裁切范围装进画布上的框。
    func beginCrop() {
        guard let photo = current else { return }
        cropDraft = photo.parameters.crop ?? [0, 0, 1, 1]
        cropAspect = "original"
        if photo.ready { schedulePreview() }
    }

    var cropPreviewing: Bool { inspectorTab == "crop" }

    /// 选比例：在当前画面里取一个居中的最大框。
    func applyCropAspect(_ ratio: Double?) {
        guard let photo = current else { return }
        var width = Double(photo.imported.width), height = Double(photo.imported.height)
        if Int(photo.parameters.rotation) % 180 == 90 { swap(&width, &height) }
        guard let ratio, width > 0, height > 0 else { cropDraft = [0, 0, 1, 1]; return }
        // 归一化框的横向/纵向比是 k 时，画出来的实际比例是 k × 原画面比例。
        let k = ratio / (width / height)
        var cw = 1.0, ch = 1.0
        if k >= 1 { ch = 1 / k } else { cw = k }
        cropDraft = [(1 - cw) / 2, (1 - ch) / 2, cw, ch]
    }

    func rotateQuarter(_ direction: Int) {
        guard current != nil else { return }
        // 画面转了，原来的框就不作数了，清掉重新框。
        cropDraft = [0, 0, 1, 1]
        change(direction > 0 ? "顺时针旋转 90°" : "逆时针旋转 90°") { parameters in
            var value = (parameters.rotation + Double(direction * 90)).truncatingRemainder(dividingBy: 360)
            if value < 0 { value += 360 }
            parameters.rotation = value
            parameters.crop = nil
        }
    }

    func toggleFlip(_ axis: String) {
        guard current != nil else { return }
        let title = axis == "h" ? "水平翻转" : "垂直翻转"
        cropDraft = [0, 0, 1, 1]
        change(title) { parameters in
            parameters.flip = parameters.flip == axis ? "" : axis
            parameters.crop = nil
        }
    }

    /// 松手才应用：整段拖动只记一条历史、只重算一次画面。
    func applyAngle(_ angle: Double) {
        change(abs(angle) < 0.01 ? "取消旋转" : String(format: "旋转 %.1f°", angle)) { $0.angle = angle }
    }

    func straightenPreview(_ angle: Double) {
        // 拖动拉直滑杆时只改角度，不每一步都记历史。
        beginEditing("拉直画面")
        update { $0.angle = angle }
    }

    func finishStraighten() {
        finishEditing()
    }

    /// 框好了就写进参数，画布随即显示裁切后的画面。
    /// 「确定」：把框定的范围写进照片，然后回到刚才那一页。
    func finishCrop() {
        commitCrop()
        inspectorTab = lastMainTab
    }

    func commitCrop() {
        guard let draft = cropDraft else { return }
        let full = draft[0] < 0.001 && draft[1] < 0.001 && draft[2] > 0.999 && draft[3] > 0.999
        change(full ? "恢复整幅画面" : "裁切画面") { parameters in
            parameters.crop = full ? nil : draft
        }
    }

    func resetGeometry() {
        guard current != nil else { return }
        cropDraft = [0, 0, 1, 1]
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
                recordChange("应用裁切与旋转", before: before)
                status = "裁切与旋转已应用，可以继续画选区了"
                schedulePreview(); loadAnalysis()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// 右栏的裁切页：比例、旋转、翻转、拉直，加上一个「应用」把几何固定下来。
struct CropPanel: View {
    @Bindable var store: WorkspaceStore
    /// 拖动滑杆时的临时角度：这时不重算画面，松手才应用
    @State private var angleDraft: Double?
    private let aspects: [(String, String, Double?)] = [
        ("original", "原始", nil), ("1:1", "1:1", 1), ("4:3", "4:3", 4.0 / 3),
        ("5:4", "5:4", 5.0 / 4), ("3:2", "3:2", 3.0 / 2), ("16:9", "16:9", 16.0 / 9),
        ("9:16", "9:16", 9.0 / 16), ("4:5", "4:5", 4.0 / 5)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("比例") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                        ForEach(aspects, id: \.0) { item in
                            Button {
                                store.cropAspect = item.0
                                store.applyCropAspect(item.2)
                            } label: {
                                Text(item.1).font(.callout)
                                    .frame(maxWidth: .infinity).frame(height: 30)
                                    .background(store.cropAspect == item.0 ? Color(red: 0.18, green: 0.42, blue: 0.57) : Color(white: 0.24),
                                                in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("在画面上拖动裁切框，拖四个角改大小，拖框内移动位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("旋转") {
                    HStack(spacing: 8) {
                        textButton("向左转", icon: "rotate.left") { store.rotateQuarter(-1) }
                        textButton("向右转", icon: "rotate.right") { store.rotateQuarter(1) }
                    }
                    HStack(spacing: 8) {
                        textButton("左右镜像", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") { store.toggleFlip("h") }
                        textButton("上下镜像", icon: "arrow.up.and.down.righttriangle.up.righttriangle.down") { store.toggleFlip("v") }
                    }
                    Text("镜像就是把画面翻个面，自拍、倒影校正时才用得上。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("自由旋转") {
                    HStack(spacing: 10) {
                        AngleSlider(value: Binding(get: { angleDraft ?? store.current?.parameters.angle ?? 0 },
                                                   set: { value in
                                                       angleDraft = value
                                                       store.angleDraft = value
                                                   }),
                                    range: -180...180) {
                            if let value = angleDraft { store.applyAngle(value) }
                            angleDraft = nil
                            store.angleDraft = 0
                        }
                        Text(String(format: "%.1f°", angleDraft ?? store.current?.parameters.angle ?? 0))
                            .font(.caption).monospacedDigit().frame(width: 46, alignment: .trailing)
                    }
                    Text("任意角度都能转。拖动时只动数字，松手才重算画面；转完的空边会自动裁掉。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Button { store.finishCrop() } label: {
                    Label("确定", systemImage: "checkmark").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(store.controlsBlocked)
                    .keyboardShortcut(.defaultAction)
                    .help("也可以直接按回车")

                Button("恢复原始构图") { store.resetGeometry() }
                    .buttonStyle(.link).disabled(store.controlsBlocked || !(store.current?.parameters.hasGeometry ?? false))
            }.padding(16)
        }
        .onAppear { store.beginCrop() }
    }

    private func textButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color(white: 0.24), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(store.controlsBlocked)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 自绘的角度滑杆：轨道 + 圆钮，纯净没有系统控件那条多余的横线。
private struct AngleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let ratio = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.30)).frame(height: 4)
                Capsule().fill(Color.white.opacity(0.9)).frame(width: width * ratio, height: 4)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(width - 14, max(0, width * ratio - 7)))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let ratio = min(1, max(0, drag.location.x / width))
                        value = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in onCommit() }
            )
        }.frame(height: 18)
    }
}

/// 画布上的裁切框：外面压暗，里面画三分线，四角和四条边都能拖。
struct CropOverlay: View {
    @Bindable var store: WorkspaceStore
    let size: CGSize

    private var box: [Double] { store.cropDraft ?? [0, 0, 1, 1] }

    var body: some View {
        let w = size.width, h = size.height
        let rect = CGRect(x: box[0] * w, y: box[1] * h, width: box[2] * w, height: box[3] * h)
        ZStack(alignment: .topLeading) {
            // 框外压暗
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

            Rectangle().path(in: rect).stroke(Color.white.opacity(0.9), lineWidth: 1)

            // 三分线
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }.stroke(Color.white.opacity(0.28), lineWidth: 0.7)

            // 四个角画 L 形托角（Lightroom 那种），其余位置不画东西——
            // 中间那条短白条以前容易被看成一条虚横线，去掉。
            Path { path in
                let arm = min(22, min(rect.width, rect.height) / 3)
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

            // 手柄本身不画出来，只作为拖拽热区；四条边也能拖，鼠标上去会变十字光标。
            ForEach(Array(handles.enumerated()), id: \.offset) { _, handle in
                let point = CGPoint(x: handle.point(in: rect).x, y: handle.point(in: rect).y)
                Color.clear
                    .frame(width: handle.corner ? 26 : 18, height: handle.corner ? 26 : 18)
                    .position(point)
                    .gesture(drag(handle))
            }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .gesture(drag(.inside))
    }

    private enum Handle {
        case inside, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

        var corner: Bool {
            switch self { case .topLeft, .topRight, .bottomLeft, .bottomRight: return true; default: return false }
        }

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .inside: return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
    }

    private var handles: [Handle] { [.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .bottom, .left, .right] }

    private func drag(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 1, size.height > 1 else { return }
                var current = store.cropDraft ?? [0, 0, 1, 1]
                let dx = Double(value.translation.width / size.width)
                let dy = Double(value.translation.height / size.height)
                let start = store.cropAnchor ?? current
                if store.cropAnchor == nil { store.cropAnchor = current }
                let minSize = 0.08
                switch handle {
                case .inside:
                    let nx = min(max(0, start[0] + dx), 1 - start[2])
                    let ny = min(max(0, start[1] + dy), 1 - start[3])
                    current[0] = nx; current[1] = ny
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
                }
                current[2] = max(minSize, min(current[2], 1 - current[0]))
                current[3] = max(minSize, min(current[3], 1 - current[1]))
                store.cropDraft = current
                store.cropAspect = "free"
            }
            .onEnded { _ in store.cropAnchor = nil }
    }
}
