import AppKit
import SwiftUI

/// 左栏：上面是图集（导入过的每一批照片，关掉应用再打开还在），下面是这一批的操作历史。
/// 跟 Lightroom 的目录树 + 历史面板是一个用法：点哪条就回到哪一条。
struct LibrarySidebar: View {
    @Bindable var store: WorkspaceStore
    @State private var renamingID: String?
    @State private var draftTitle = ""
    @State private var pendingDelete: LibraryAlbum?
    @State private var hoveredStep: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                albumsSection
                Divider().padding(.vertical, 6)
                historySection
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
                Text("图集").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.startFreshWorkspace() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).font(.system(size: 11)).help("新建图集")
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
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("历史记录").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !store.albumSteps.isEmpty {
                    Button("清空") { store.clearSteps() }.buttonStyle(.plain)
                        .font(.system(size: 10)).foregroundStyle(.secondary).help("清空记录，画面不变")
                }
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if store.albumSteps.isEmpty {
                Text(store.currentAlbumID == nil ? "打开图集后，调整记录显示在这里。" : "暂无调整记录。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(Array(store.albumSteps.reversed())) { step in stepRow(step) }
            }
        }
    }

    private func stepRow(_ step: LibraryStep) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(step.label).font(.system(size: 11)).lineLimit(1)
                Text("\(step.states.count) 张 · \(step.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hoveredStep == step.id {
                Button { store.deleteStep(step) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("删除这条记录，画面不变")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { store.revertToStep(step) }
        .onHover { inside in hoveredStep = inside ? step.id : (hoveredStep == step.id ? nil : hoveredStep) }
        .help("回到这一步的调整")
    }
}
