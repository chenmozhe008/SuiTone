import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text("照片").font(.headline)
                Spacer()
                Text("\(store.photos.count)").foregroundStyle(.secondary)
            }.padding(14)
            ScrollView {
              LazyVStack(spacing:2) {
                ForEach(store.photos) {photo in
                  Button {store.selectPhoto(photo.id,modifiers:NSEvent.modifierFlags)} label:{
                    VStack(alignment:.leading,spacing:5) {
                        LocalPhoto(path:photo.imported.thumbnail).frame(maxWidth:.infinity).frame(height:100)
                        HStack(spacing:4) {
                            if photo.starred {Image(systemName:"star.fill").font(.caption2)}
                            Text(photo.imported.name).font(.caption).lineLimit(1)
                            Spacer(minLength:0)
                            if photo.excluded {Image(systemName:"xmark.circle").foregroundStyle(.secondary)}
                            else if photo.imported.similarTo != nil {Image(systemName:"square.on.square").help("有构图相似的照片，仅作提示")}
                        }
                    }
                    .opacity(photo.excluded ? 0.4:1)
                    .padding(8)
                    .background(store.selectedIDs.contains(photo.id) ? Color(white:0.28):Color.clear)
                  }.buttonStyle(.plain)
                    .accessibilityLabel(photo.imported.name)
                    .accessibilityValue(store.selectedIDs.contains(photo.id) ? "已选择":"")
                    .contextMenu {
                        Button(photo.starred ? "取消标星":"标星") {store.toggleStar(photo.id)}
                        Button(photo.excluded ? "恢复选用":"排除") {store.toggleExcluded(photo.id)}
                    }
                }
              }.padding(.horizontal,5)
            }
            .onChange(of:store.selectedIDs) {_, ids in
                if !ids.contains(store.currentID ?? "") {store.activate(store.photos.first(where:{ids.contains($0.id)})?.id)}
            }
            HStack {Text("⌘ 多选 · 右键标星／排除").font(.caption2).foregroundStyle(.secondary);Spacer()}.padding(10)
        }
        .background(Color(white:0.13))
        .dropDestination(for:URL.self) {urls,_ in store.importURLs(urls);return true}
    }
}
