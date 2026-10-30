import SwiftUI

struct PhotoCanvas: View {
    @Bindable var store: WorkspaceStore
    @State private var drawing = false
    @State private var drawingChatSelection = false
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
                        // 自由旋转拖动中：本地先转，松手才由引擎重算，手感即时
                        .rotationEffect(.degrees(liveAngle))
                        .scaleEffect(coverScale(w: w, h: h, angle: liveAngle))
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
                    if let box=store.selectionBox,((store.repairEnabled || store.inspectorTab == "chat") && store.repairTool == "box"),store.repairDraft == nil {
                        Rectangle().stroke(.white,lineWidth:1).background(.white.opacity(0.08))
                            .frame(width:w*(box[2]-box[0]),height:h*(box[3]-box[1]))
                            .position(x:w*(box[0]+box[2])/2,y:h*(box[1]+box[3])/2)
                    }
                    // 裁切页：框出要留下的范围，外面压暗。
                    if store.inspectorTab == "crop", store.cropDraft != nil {
                        CropOverlay(store: store, size: CGSize(width: w, height: h))
                    }
                }
                .frame(width:w,height:h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onEnded {value in
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
                    // 调整页里点一下照片：选中所在区域做局部调整。
                    guard store.inspectorTab == "adjust", !splitActive, tap else {return}
                    store.pickRegion(x:point[0],y:point[1])
                }.onChanged {value in
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
                .overlay(alignment:.top) {
                    if store.repairEnabled && store.usesSelectionParts && store.repairDraft == nil { SelectionToolbar(store:store).padding(.top,6) }
                }

                .overlay(alignment:.bottomLeading) {
                    if store.inspectorTab == "aiedit" && store.versionPreview != nil {canvasLabel("版本预览，照片未改动").padding(10)}
                    else if store.showOriginal {canvasLabel("原图").padding(10)}
                    else if store.repairDraft != nil {canvasLabel(store.repairShowingBefore ? "修复前" : "修复预览").padding(10)}
                    else if store.inspectorTab == "aiedit" && store.selectionOverlay != nil && !store.selectionParts.isEmpty {
                        canvasLabel("选区：只改这块", color: .cyan).padding(10)
                    }
                    else if !store.overlay.isEmpty && !splitActive {
                        canvasLabel(store.overlay.hasPrefix("selection-") ? "选区" : RegionNames.title(store.overlay)+"选区").padding(10)
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
    /// 拖动自由旋转时相对已提交角度的增量
    private var liveAngle: Double {
        guard store.inspectorTab == "crop", store.angleDraft != 0 else { return 0 }
        return store.angleDraft - (store.current?.parameters.angle ?? 0)
    }

    /// 转过之后要放大一点，画面才不会露出空白角。
    private func coverScale(w: CGFloat, h: CGFloat, angle: Double) -> CGFloat {
        guard abs(angle) > 0.01, w > 1, h > 1 else { return 1 }
        let radians = abs(angle) * .pi / 180
        let cosine = abs(cos(radians)), sine = abs(sin(radians))
        return max(1, max((w * cosine + h * sine) / w, (w * sine + h * cosine) / h))
    }

    private func displayRatio(_ photo: PhotoRecord) -> CGFloat {
        // 以渲染出来的预览为准：旋转、自由旋转、裁切都已经算进这张图里了，
        // 自己再按原图比例推一遍，转到 90° 时裁切框就会跑到画面外面（框和照片对不上）。
        if let path = photo.previewPath, let ratio = PhotoSize.ratio(path) { return ratio }
        var width = Double(photo.imported.width), height = Double(photo.imported.height)
        if store.inspectorTab != "crop" {
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
            if let p=store.repairPoint {
                let r=CGRect(x:p[0]*w-7,y:p[1]*h-7,width:14,height:14)
                context.fill(Path(ellipseIn:r),with:.color(red));context.stroke(Path(ellipseIn:r),with:.color(.white),lineWidth:2)
            }
        }.frame(width:w,height:h).allowsHitTesting(false)
    }

    /// 修复、看选区或整张看原图时不叠加滑动对比，避免两种对比同时出现。
    private var splitActive: Bool {
        store.splitCompare && !store.showOriginal && !store.repairEnabled && store.repairDraft == nil && store.overlay.isEmpty
            && !(store.inspectorTab == "aiedit" && !store.selectionParts.isEmpty)
    }

    private func canvasLabel(_ text:String, color: Color = .white)->some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal,9).padding(.vertical,5)
            .background(.black.opacity(0.45),in:Capsule()).padding(10)
    }

    private func displayPath(_ photo:PhotoRecord)->String {
        if store.inspectorTab == "aiedit", let version = store.versionPreview {return version}
        if store.showOriginal {return photo.imported.original}
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
