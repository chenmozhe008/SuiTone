import SwiftUI

struct PhotoCanvas: View {
    @Bindable var store: WorkspaceStore
    @State private var drawing = false
    @State private var drawingChatSelection = false
    var body: some View {
        GeometryReader {geometry in
            if let photo=store.current {
                let ratio=CGFloat(photo.imported.width)/CGFloat(photo.imported.height)
                let w=max(1,min(geometry.size.width-48,(geometry.size.height-48)*ratio))
                let h=w/ratio
                ZStack {
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
                    if store.repairEnabled && store.repairDraft == nil && store.repairMaskOverlay == nil {
                        repairShapes(w:w,h:h)
                    }
                    if let box=store.selectionBox,(store.repairEnabled && store.repairTool == "box" || store.inspectorTab == "chat"),store.repairDraft == nil {
                        Rectangle().stroke(.white,lineWidth:1).background(.white.opacity(0.08))
                            .frame(width:w*(box[2]-box[0]),height:h*(box[3]-box[1]))
                            .position(x:w*(box[0]+box[2])/2,y:h*(box[1]+box[3])/2)
                    }
                }
                .frame(width:w,height:h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onEnded {value in
                    if drawingChatSelection { drawingChatSelection = false; return }
                    let tap=hypot(value.translation.width,value.translation.height)<4
                    let point=[Double(min(1,max(0,value.location.x/w))),Double(min(1,max(0,value.location.y/h)))]
                    if store.repairEnabled {
                        guard !store.busy, store.repairDraft == nil else {return}
                        if store.repairTool == "object" && tap {
                            store.repairPoint=point;store.updateRepairBounds();store.previewRepairMask()
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
                        store.selectionBox=[min(x0,point[0]),min(y0,point[1]),max(x0,point[0]),max(y0,point[1])]
                    default: break
                    }
                })
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .overlay(alignment:.bottomLeading) {
                    if store.showOriginal {canvasLabel("原图").padding(10)}
                    else if store.repairDraft != nil {canvasLabel(store.repairShowingBefore ? "修复前" : "修复预览").padding(10)}
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

    /// 画笔轨迹（半透明红，粗细即笔刷大小）、套索轮廓、点选位置。
    @ViewBuilder private func repairShapes(w:CGFloat,h:CGFloat)->some View {
        let red=Color(red:0.95,green:0.3,blue:0.3)
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
    }

    private func canvasLabel(_ text:String)->some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal,9).padding(.vertical,5)
            .background(.black.opacity(0.45),in:Capsule()).padding(10)
    }

    private func displayPath(_ photo:PhotoRecord)->String {
        if store.showOriginal {return photo.imported.original}
        if let draft = store.repairDraft, draft.photoID == photo.id {
            return store.repairShowingBefore ? draft.beforePath : draft.previewPath
        }
        if store.repairEnabled,let path=store.repairMaskOverlay {return path}
        if store.overlay.hasPrefix("selection-"), let path=store.manualOverlay {return path}
        if let overlay=store.analysis?.overlays[store.overlay] {return overlay}
        return photo.previewPath ?? photo.imported.original
    }
}
