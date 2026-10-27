import SwiftUI

struct PhotoCanvas: View {
    @Bindable var store: WorkspaceStore
    @State private var dragStart: CGPoint?
    var body: some View {
        GeometryReader {geometry in
            if let photo=store.current {
                let ratio=CGFloat(photo.imported.width)/CGFloat(photo.imported.height)
                let w=min(geometry.size.width-40,(geometry.size.height-50)*ratio)
                let h=w/ratio
                ZStack {
                    LocalPhoto(path:displayPath(photo)).frame(width:w,height:h)
                    if let box=store.selectionBox,store.repairEnabled {
                        Rectangle().stroke(.white,lineWidth:1).background(.white.opacity(0.08))
                            .frame(width:w*(box[2]-box[0]),height:h*(box[3]-box[1]))
                            .position(x:w*(box[0]+box[2])/2,y:h*(box[1]+box[3])/2)
                    }
                }
                .frame(width:w,height:h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:2).onChanged {value in
                    guard store.repairEnabled else {return}
                    store.repairMaskOverlay=nil
                    let clamp:(CGFloat)->CGFloat={min(1,max(0,$0))}
                    let x0=clamp(value.startLocation.x/w),y0=clamp(value.startLocation.y/h)
                    let x1=clamp(value.location.x/w),y1=clamp(value.location.y/h)
                    store.selectionBox=[min(x0,x1),min(y0,y1),max(x0,x1),max(y0,y1)].map(Double.init)
                })
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .overlay(alignment:.bottomLeading) {
                    if store.showOriginal {Text("原图").font(.caption).padding(8).background(Color(white:0.12)).padding(10)}
                    else if !store.overlay.isEmpty {Text(RegionNames.title(store.overlay)+"选区").font(.caption).padding(8).background(Color(white:0.12)).padding(10)}
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

    private func displayPath(_ photo:PhotoRecord)->String {
        if store.showOriginal {return photo.imported.original}
        if store.repairEnabled,let path=store.repairMaskOverlay {return path}
        if let overlay=store.analysis?.overlays[store.overlay] {return overlay}
        return photo.previewPath ?? photo.imported.original
    }
}
