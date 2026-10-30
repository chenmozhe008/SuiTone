import AppKit
import SwiftUI

/// 左栏：导入过的图集。
struct LibrarySidebar: View {
    @Bindable var store: WorkspaceStore
    @State private var renamingID: String?
    @State private var draftTitle = ""
    @State private var pendingDelete: LibraryAlbum?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                albumsSection
            }.padding(.bottom, 10)
        }
        .background(Color(white: 0.125))
        .alert("重命名图集", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("名称", text: $draftTitle)
            Button("保存") { if let id = renamingID { store.renameAlbum(id, to: draftTitle) }; renamingID = nil }
            Button("取消", role: .cancel) { renamingID = nil }
        }
        .alert("把这个图集从列表里移除？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("移除", role: .destructive) { if let album = pendingDelete { store.deleteAlbum(album.id) }; pendingDelete = nil }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只会去掉这条记录和它的调整，磁盘上的照片文件不会被删除。")
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("图集").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button { store.startFreshWorkspace() } label: { Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("新建图集").accessibilityLabel("新建图集")
                    .disabled(store.controlsBlocked)
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)

            if store.albums.isEmpty {
                Text("暂无图集。导入照片后会自动建立一条记录。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                ForEach(store.albums) { album in albumRow(album) }
            }
        }
    }

    private func albumRow(_ album: LibraryAlbum) -> some View {
        HStack(spacing: 8) {
            LocalPhoto(path: album.cover ?? "", fill: true)
                .frame(width: 44, height: 31)
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).font(.system(size: 12, weight: album.id == store.currentAlbumID ? .semibold : .regular)).lineLimit(1)
                Text("\(album.photos.count) 张 · \(album.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(album.id == store.currentAlbumID ? Color(white: 0.26) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { store.openAlbum(album) }
        .contextMenu {
            Button("打开") { store.openAlbum(album) }
            Button("重命名…") { draftTitle = album.title; renamingID = album.id }
            Button("在访达中显示") {
                if let first = album.photos.first { NSWorkspace.shared.selectFile(first.path, inFileViewerRootedAtPath: "") }
            }
            Divider()
            Button("移除此图集", role: .destructive) { pendingDelete = album }
        }
        .accessibilityLabel("图集 \(album.title)，\(album.photos.count) 张")
    }

}
