import SwiftUI

struct PhotoCanvas: View {
    @Bindable var store: WorkspaceStore
    @State private var dragStart: CGPoint?
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
                    if let box=store.selectionBox,(store.repairEnabled || store.inspectorTab == "chat"),store.repairDraft == nil {
                        Rectangle().stroke(.white,lineWidth:1).background(.white.opacity(0.08))
                            .frame(width:w*(box[2]-box[0]),height:h*(box[3]-box[1]))
                            .position(x:w*(box[0]+box[2])/2,y:h*(box[1]+box[3])/2)
                    }
                }
                .frame(width:w,height:h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged {value in
                    if splitActive {store.splitPosition=min(1,max(0,value.location.x/w));return}
                    guard value.translation != .zero, store.repairEnabled, !store.busy, store.repairDraft == nil else {return}
                    store.repairMaskOverlay=nil
                    let clamp:(CGFloat)->CGFloat={min(1,max(0,$0))}
                    let x0=clamp(value.startLocation.x/w),y0=clamp(value.startLocation.y/h)
                    let x1=clamp(value.location.x/w),y1=clamp(value.location.y/h)
                    store.selectionBox=[min(x0,x1),min(y0,y1),max(x0,x1),max(y0,y1)].map(Double.init)
                })
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .overlay(alignment:.bottomLeading) {
                    if store.showOriginal {canvasLabel("原图").padding(10)}
                    else if store.repairDraft != nil {canvasLabel(store.repairShowingBefore ? "修复前" : "修复预览").padding(10)}
                    else if !store.overlay.isEmpty && !splitActive {canvasLabel(RegionNames.title(store.overlay)+"选区").padding(10)}
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
        if let overlay=store.analysis?.overlays[store.overlay] {return overlay}
        return photo.previewPath ?? photo.imported.original
    }
}
