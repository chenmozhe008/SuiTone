import AppKit
import SwiftUI

struct PhotoCanvas: View {
    @Bindable var store: WorkspaceStore
    @State private var drawing = false
    @State private var drawingChatSelection = false
    /// 裁切拖动：按下时抓到的框和手柄，整段拖动沿用，不跟着重算
    @State private var cropStart: [Double]?
    @State private var cropHandle: CropGeometry.Handle?
    @State private var cropCursor: CropCursor = .arrow
    var body: some View {
        GeometryReader {geometry in
            if let photo=store.current {
                let ratio=displayRatio(photo)
                let w=max(1,min(geometry.size.width-48,(geometry.size.height-48)*ratio))
                let h=w/ratio
                ZStack {
                    if store.inspectorTab == "cutout" && store.cutoutPreview != nil {
                        Canvas { context, size in
                            let cell: CGFloat = 12
                            for row in 0..<Int(ceil(size.height / cell)) {
                                for column in 0..<Int(ceil(size.width / cell)) {
                                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                                    context.fill(Path(rect), with: .color((row + column).isMultiple(of: 2) ? .white.opacity(0.8) : .gray.opacity(0.8)))
                                }
                            }
                        }.frame(width:w,height:h)
                    }
                    LocalPhoto(path:displayPath(photo)).frame(width:w,height:h)
                    if splitActive {
                        let x=w*store.splitPosition
                        LocalPhoto(path:photo.imported.original).frame(width:w,height:h)
                            .mask(alignment:.leading) {Rectangle().frame(width:x)}
                        Rectangle().fill(.white).frame(width:1.5,height:h).position(x:x,y:h/2).shadow(radius:2)
                        Image(systemName:"chevron.left.chevron.right").font(.system(size:11,weight:.semibold))
                            .foregroundStyle(.black).frame(width:30,height:30).background(.white,in:Circle()).shadow(radius:3)
                            .position(x:x,y:h/2)
                        HStack {
                            canvasLabel("原图").opacity(store.splitPosition>0.08 ? 1 : 0)
                            Spacer()
                            canvasLabel("调整后").opacity(store.splitPosition<0.92 ? 1 : 0)
                        }.frame(width:w,height:h,alignment:.top)
                    }
                    // AI 改图页不画选区，但已经画好的选区要留着看得见：否则切回来不知道这次会改哪一块。
                    if (store.repairEnabled || store.inspectorTab == "aiedit"), store.usesSelectionParts, store.repairDraft == nil, store.repairMaskOverlay == nil, let overlay = store.selectionOverlay {
                        LocalPhoto(path: overlay).frame(width: w, height: h).allowsHitTesting(false)
                    }
                    if store.usesSelectionParts, let b = store.selectionDraftBox {
                        Rectangle().stroke(store.selectionSubtract ? Color.orange : .white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .frame(width: w*(b[2]-b[0]), height: h*(b[3]-b[1])).position(x: w*(b[0]+b[2])/2, y: h*(b[1]+b[3])/2)
                            .allowsHitTesting(false)
                    }
                    if store.inspectorTab == "adjust", store.localRegion != nil, store.overlay.isEmpty, !splitActive,
                       let outline = store.localOutline {
                        LocalPhoto(path: outline).frame(width: w, height: h).allowsHitTesting(false)
                    }
                    if (store.repairEnabled || (store.inspectorTab == "chat" && store.repairTool != "box")) && store.repairDraft == nil && store.repairMaskOverlay == nil {
                        repairShapes(w:w,h:h)
                    }
                    // 只有对话页还需要这个白框标出「这次会改哪一块」；
                    // 选区／移除页画完的框已经合成了红色选区图，再压一个白框就是多余的那道线。
                    if store.inspectorTab == "chat", let box=store.selectionBox, store.repairTool == "box",
                       store.repairDraft == nil, store.selectionOverlay == nil, store.repairMaskOverlay == nil {
                        Rectangle().stroke(.white,lineWidth:1).background(.white.opacity(0.08))
                            .frame(width:w*(box[2]-box[0]),height:h*(box[3]-box[1]))
                            .position(x:w*(box[0]+box[2])/2,y:h*(box[1]+box[3])/2)
                    }
                    // 裁切页：框出要留下的范围，外面压暗。确定之后框收起来，画面就是裁好的样子。
                    if store.inspectorTab == "crop", store.cropEditing {
                        CropOverlay(size: CGSize(width: w, height: h),
                                    box: store.cropDraft ?? [0, 0, 1, 1],
                                    pixels: PhotoSize.pixels(displayPath(photo)))
                    }
                }
                .frame(width:w,height:h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onEnded {value in
                    if store.inspectorTab == "crop" { return }
                    if drawingChatSelection { drawingChatSelection = false; return }
                    let tap=hypot(value.translation.width,value.translation.height)<4
                    let point=[Double(min(1,max(0,value.location.x/w))),Double(min(1,max(0,value.location.y/h)))]
                    if store.repairEnabled && store.usesSelectionParts {
                        guard !store.busy, store.repairDraft == nil else {return}
                        if store.repairTool == "object" { if tap { store.repairPoint=point; store.commitSelectionPart() } }
                        else { drawing=false; store.commitSelectionPart() }
                        return
                    }
                    if store.repairEnabled {
                        guard !store.busy, store.repairDraft == nil else {return}
                        if store.inspectorTab == "cutout" && store.cutoutPreview != nil { return }
                        if store.repairTool == "object" && tap {
                            store.repairPoint=point;store.updateRepairBounds()
                            if store.inspectorTab == "cutout" { store.previewCutout() } else { store.previewRepairMask() }
                        } else if store.repairTool == "brush" || store.repairTool == "lasso" {
                            drawing=false;store.updateRepairBounds()
                        }
                        return
                    }
                    if store.inspectorTab == "chat", tap, store.selectionBox != nil {
                        store.clearRepairSelection()
                        return
                    }
                    // 调整页里点一下照片：选中所在区域做局部调整。
                    guard store.inspectorTab == "adjust", !splitActive, tap else {return}
                    store.pickRegion(x:point[0],y:point[1])
                }.onChanged {value in
                    if store.inspectorTab == "crop" { return }
                    if splitActive {store.splitPosition=min(1,max(0,value.location.x/w));return}
                    if store.inspectorTab == "chat", !store.repairEnabled, !store.controlsBlocked, !store.chatting {
                        guard hypot(value.translation.width,value.translation.height)>=4 || drawingChatSelection else { return }
                        if !drawingChatSelection { drawingChatSelection=true;store.beginChatSelection() }
                        let clamp:(CGFloat)->Double={Double(min(1,max(0,$0)))}
                        store.updateChatSelection(from:[clamp(value.startLocation.x/w),clamp(value.startLocation.y/h)],
                                                  to:[clamp(value.location.x/w),clamp(value.location.y/h)])
                        return
                    }
                    guard store.repairEnabled, !store.busy, store.repairDraft == nil else {return}
                    let clamp:(CGFloat)->Double={Double(min(1,max(0,$0)))}
                    let point=[clamp(value.location.x/w),clamp(value.location.y/h)]
                    switch store.repairTool {
                    case "brush":
                        // 每次按下开始一笔新的轨迹；多笔累加，「重新选择」清空。
                        if !drawing {drawing=true;store.repairMaskOverlay=nil;store.repairStrokes.append([point])}
                        else if let last=store.repairStrokes.last?.last,hypot(last[0]-point[0],last[1]-point[1])>0.002 {
                            store.repairStrokes[store.repairStrokes.count-1].append(point)
                        }
                    case "lasso":
                        if !drawing {drawing=true;store.repairMaskOverlay=nil;store.repairPolygon=[point]}
                        else if let last=store.repairPolygon.last,hypot(last[0]-point[0],last[1]-point[1])>0.004 {store.repairPolygon.append(point)}
                    case "box":
                        guard value.translation != .zero else {return}
                        store.repairMaskOverlay=nil
                        let x0=clamp(value.startLocation.x/w),y0=clamp(value.startLocation.y/h)
                        let frame=[min(x0,point[0]),min(y0,point[1]),max(x0,point[0]),max(y0,point[1])]
                        if store.usesSelectionParts { store.selectionDraftBox=frame } else { store.selectionBox=frame }
                    default: break
                    }
                })
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                // 裁切页的拖动层：铺满整块画布，从照片外的灰底起手也照样能拖（PS 也是这样）。
                // 只挂在照片矩形上的话，手一偏落在灰底上就完全没反应，看起来就是「框拖不动」。
                .overlay {
                    if store.inspectorTab == "crop", store.cropEditing {
                        cropDragLayer(origin: CGPoint(x: (geometry.size.width - w) / 2, y: (geometry.size.height - h) / 2),
                                      size: CGSize(width: w, height: h))
                    }
                }

                .overlay(alignment:.bottom) {
                    // 拖拉直滑杆时在画面上直接给角度，眼睛不用在画面和右栏之间来回找。
                    if store.inspectorTab == "crop", let angle = store.angleDraft {
                        Text(String(format: "%+.1f°", angle))
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
                .overlay(alignment:.bottomLeading) {
                    if store.inspectorTab == "crop" { canvasLabel(cropHint).padding(10).allowsHitTesting(false) }
                    else if store.inspectorTab == "aiedit" && store.versionPreview != nil {canvasLabel("版本预览，照片未改动").padding(10)}
                    else if store.showOriginal {canvasLabel("原图").padding(10)}
                    else if store.repairDraft != nil {canvasLabel(store.repairShowingBefore ? "修复前" : "修复预览").padding(10)}
                    else if store.inspectorTab == "aiedit" && store.selectionOverlay != nil && !store.selectionParts.isEmpty {
                        canvasLabel("选区：只改这块", color: .cyan).padding(10)
                    }
                    else if !store.overlay.isEmpty && !splitActive {
                        canvasLabel(store.overlay.hasPrefix("selection-") ? "选区" : RegionNames.title(store.overlay)+"选区").padding(10)
                    }
                    else if store.repairEnabled && store.usesSelectionParts && store.repairDraft == nil {
                        canvasLabel(selectionHint).padding(10)
                    }
                }
            } else {
                VStack(spacing:16) {
                    Image(systemName:"photo.on.rectangle.angled").font(.system(size:38,weight:.ultraLight)).foregroundStyle(.secondary)
                    Text("把照片或文件夹拖进来").font(.title3)
                    Text("先选目标照片，再在上方添加参考图").font(.callout).foregroundStyle(.secondary)
                    Button("导入照片…") {store.chooseImport()}.disabled(store.busy)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .dropDestination(for:URL.self) {urls,_ in store.importURLs(urls);return true}
    }

    /// 画面显示比例：按裁切和旋转后实际要出的形状算，裁切页里仍显示完整画面以便重新框。
    private func displayRatio(_ photo: PhotoRecord) -> CGFloat {
        // 以渲染出来的预览为准：旋转、自由旋转、裁切都已经算进这张图里了，
        // 自己再按原图比例推一遍，转到 90° 时裁切框就会跑到画面外面（框和照片对不上）。
        if let path = photo.previewPath, let ratio = PhotoSize.ratio(path) { return ratio }
        var width = Double(photo.imported.width), height = Double(photo.imported.height)
        if !store.cropPreviewing {
            if let crop = photo.parameters.crop, crop[2] > 0, crop[3] > 0 {
                width *= crop[2]; height *= crop[3]
            }
            if Int(photo.parameters.rotation) % 180 == 90 { swap(&width, &height) }
        }
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width / height)
    }

    /// 画笔轨迹（半透明红，粗细即笔刷大小）、套索轮廓、点选位置。
    @ViewBuilder private func repairShapes(w:CGFloat,h:CGFloat)->some View {        // 正在画的这一笔：添加用红色，减去用橙色
        let red=store.usesSelectionParts && store.selectionSubtract ? Color.orange : Color(red:0.95,green:0.3,blue:0.3)
        Canvas {context,_ in
            for stroke in store.repairStrokes {
                var path=Path()
                for (i,p) in stroke.enumerated() {
                    let pt=CGPoint(x:p[0]*w,y:p[1]*h)
                    if i==0 {path.move(to:pt);path.addLine(to:pt)} else {path.addLine(to:pt)}
                }
                context.stroke(path,with:.color(red.opacity(0.5)),
                               style:StrokeStyle(lineWidth:2*store.brushSize*w,lineCap:.round,lineJoin:.round))
            }
            if store.repairPolygon.count>1 {
                var path=Path();path.addLines(store.repairPolygon.map {CGPoint(x:$0[0]*w,y:$0[1]*h)})
                if !drawing {path.closeSubpath();context.fill(path,with:.color(red.opacity(0.3)))}
                context.stroke(path,with:.color(.white),style:StrokeStyle(lineWidth:1.5,dash:[5,4]))
            }
            // 抠图预览出来之后就不再画这个点：主体已经抠出来了，红点留在画面上像是没完成。
            if let p=store.repairPoint, !(store.inspectorTab == "cutout" && store.cutoutPreview != nil) {
                let r=CGRect(x:p[0]*w-7,y:p[1]*h-7,width:14,height:14)
                context.fill(Path(ellipseIn:r),with:.color(red));context.stroke(Path(ellipseIn:r),with:.color(.white),lineWidth:2)
            }
        }.frame(width:w,height:h).allowsHitTesting(false)
    }

    /// 修复、看选区或整张看原图时不叠加滑动对比，避免两种对比同时出现。
    /// 裁切页也不叠加：对比线会挡在裁切框上。
    private var splitActive: Bool {
        store.inspectorTab != "crop"
            && store.splitCompare && !store.showOriginal && !store.repairEnabled && store.repairDraft == nil && store.overlay.isEmpty
            && !(store.inspectorTab == "aiedit" && !store.selectionParts.isEmpty)
    }

    /// 裁切页铺满画布的拖动层：坐标从画布换算到照片，落在灰色留白上也照常算。
    /// 框内拖动＝移动，四角四边＝改大小，其余地方（含照片外的留白）＝重新框。
    private func cropDragLayer(origin: CGPoint, size: CGSize) -> some View {
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        }
        return Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard size.width > 1, size.height > 1 else { return }
                        let from = local(value.startLocation), to = local(value.location)
                        let box = store.cropDraft ?? [0, 0, 1, 1]
                        if cropStart == nil {
                            cropStart = box
                            cropHandle = CropGeometry.handle(at: from, box: box, size: size,
                                                             freeform: store.cropAspect == "free")
                        }
                        guard let start = cropStart, let handle = cropHandle else { return }
                        store.cropDraft = CropGeometry.dragged(start: start, handle: handle, from: from, to: to, size: size,
                                                               freeform: store.cropAspect == "free")
                    }
                    .onEnded { _ in cropStart = nil; cropHandle = nil }
            )
            .onContinuousHover { phase in
                // 鼠标形状告诉人「这里能拖什么」：手形移动、箭头拉边、十字画框。
                guard case .active(let point) = phase else {
                    if cropCursor != .arrow { cropCursor = .arrow; NSCursor.arrow.set() }
                    return
                }
                let next: CropCursor
                switch CropGeometry.handle(at: local(point), box: store.cropDraft ?? [0, 0, 1, 1], size: size,
                                           freeform: store.cropAspect == "free") {
                case .inside: next = .openHand
                case .left, .right: next = .resizeHorizontal
                case .top, .bottom: next = .resizeVertical
                default: next = .crosshair
                }
                if next != cropCursor { cropCursor = next; next.cursor.set() }
            }
    }

    /// 裁切页左下角的一行提示：先把「框怎么动」讲清楚，第一次进来的人不用猜。
    private var cropHint: String {
        guard store.cropEditing else { return "裁切已应用 · 点右栏「重新框选」再裁一次" }
        let box = store.cropDraft ?? [0, 0, 1, 1]
        let full = box[0] < 0.002 && box[1] < 0.002 && box[2] > 0.998 && box[3] > 0.998
        return full ? "在照片上拖一下，框出要保留的范围"
                    : "框内拖＝移动 · 四角四边＝改大小 · 框外拖＝重新框"
    }

    private func canvasLabel(_ text:String, color: Color = .white)->some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal,9).padding(.vertical,5)
            .background(.black.opacity(0.45),in:Capsule()).padding(10)
    }

    /// 画选区时左下角的一行提示，代替以前压在照片上方的工具条。
    private var selectionHint: String {
        let tool: String
        switch store.repairTool {
        case "brush": tool = "画笔"
        case "lasso": tool = "套索"
        case "object": tool = "点选"
        default: tool = "方框"
        }
        let state = store.selectionParts.isEmpty ? "在照片上圈出要处理的部分" : "已画 \(store.selectionParts.count) 笔"
        return tool + "：" + state + (store.selectionSubtract ? "，现在是减去" : "")
    }

    private func displayPath(_ photo:PhotoRecord)->String {
        // 「原图」永远压在最前：AI 改图页正在看某个版本时，按原图也得真能看回原图。
        if store.showOriginal {return photo.imported.original}
        if store.inspectorTab == "aiedit", let version = store.versionPreview {return version}
        if let draft = store.repairDraft, draft.photoID == photo.id {
            return store.repairShowingBefore ? draft.beforePath : draft.previewPath
        }
        if store.inspectorTab == "cutout", let path=store.cutoutPreview {return path}
        if store.repairEnabled,let path=store.repairMaskOverlay {return path}
        if store.overlay.hasPrefix("selection-"), let path=store.manualOverlay {return path}
        if let overlay=store.analysis?.overlays[store.overlay] {return overlay}
        return photo.previewPath ?? photo.imported.original
    }
}

/// 裁切页的鼠标形状，让人一眼看出这里是移动、拉边还是重新框。
enum CropCursor {
    case arrow, crosshair, openHand, resizeHorizontal, resizeVertical

    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .openHand: return .openHand
        case .resizeHorizontal: return .resizeLeftRight
        case .resizeVertical: return .resizeUpDown
        }
    }
}
