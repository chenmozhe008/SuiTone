import SwiftUI

struct FilmstripView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
            if store.targets.count > 1 {
                Text("已选 \(store.targets.count) 张").fontWeight(.semibold)
                Text("改动作用于所选照片").foregroundStyle(.secondary)
                Button("把当前调整同步到所选") { store.synchronize() }.buttonStyle(.link).disabled(store.controlsBlocked)
            } else {
                Text("改动作用于当前照片").foregroundStyle(.secondary)
            }
            Spacer()
            Text("⌘ 点按可多选").foregroundStyle(.secondary)
        }.font(.callout).padding(.horizontal, 18).padding(.top, 10)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(store.photos) { photo in
                        Button { store.selectPhoto(photo.id, modifiers: NSEvent.modifierFlags) } label: {
                            VStack(spacing: 5) {
                                LocalPhoto(path: store.showOriginal ? photo.imported.thumbnail : photo.previewPath ?? photo.imported.thumbnail, fill: true)
                                    .frame(width: 112, height: 76)
                                    .background(Color(white: 0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(photo.id == store.currentID ? Color(white: 0.92) : store.targets.contains(where: { $0.id == photo.id }) ? Color(white: 0.55) : .clear, lineWidth: 2))
                                    .overlay(alignment: .topLeading) {
                                        if store.targets.count > 1 && store.targets.contains(where: { $0.id == photo.id }) {
                                            Image(systemName: "checkmark.circle.fill").font(.callout).foregroundStyle(.white, Color(red: 0.36, green: 0.55, blue: 1)).padding(4)
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if photo.starred { Image(systemName: "star.fill").font(.caption2).padding(4).background(Color(white: 0.12)) }
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        if photo.aiGenerated {
                                            HStack(spacing: 2) {
                                                Image(systemName: "sparkles").font(.system(size: 7, weight: .bold))
                                                Text("AI").font(.system(size: 8, weight: .bold))
                                            }
                                            .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2)
                                            .background(Color(red: 0.5, green: 0.3, blue: 0.95), in: Capsule())
                                            .padding(4)
                                        }
                                    }

                                Text(photo.imported.name).font(.system(size: 10)).lineLimit(1)
                                    .foregroundStyle(photo.id == store.currentID ? .primary : .secondary)
                            }.frame(width: 112).opacity(photo.excluded ? 0.35 : 1)
                        }.buttonStyle(.plain)
                            .id(photo.id)
                            .accessibilityLabel(photo.imported.name)
                            .accessibilityValue(store.selectedIDs.contains(photo.id) ? "已选择" : "")
                            .contextMenu {
                                Button("单张查看") { store.activate(photo.id); store.grid = false }
                                Button(photo.starred ? "取消标星" : "标星") { store.toggleStar(photo.id) }
                                Button(photo.excluded ? "恢复选用" : "排除") { store.toggleExcluded(photo.id) }
                                if photo.imported.similarTo != nil { Text("有构图相似的照片") }
                            }
                    }
                    Button { store.chooseImport() } label: {
                        Image(systemName: "plus").font(.title2.weight(.ultraLight))
                            .frame(width: 72, height: 76).background(Color(white: 0.17))
                    }.buttonStyle(.plain).disabled(store.controlsBlocked).help("添加照片")
                }.padding(.horizontal, 18).padding(.top, 12)
            }.scrollIndicators(.hidden)
                .onChange(of: store.currentID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } } }
        }
        }.background(Color(white: 0.12))
    }
}
