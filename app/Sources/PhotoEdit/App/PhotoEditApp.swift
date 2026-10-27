import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup(AppIdentity.windowTitle, id: "workspace") {
            ContentView(store: store)
                .preferredColorScheme(.dark)
                .task { await store.start() }
                .onOpenURL { url in
                    if url.pathExtension=="photoedit" {store.openProject(url)}
                    else {store.importURLs([url])}
                }
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入照片…") { store.chooseImport() }.keyboardShortcut("o")
                Button("添加参考图…") { store.chooseImport(reference: true) }.keyboardShortcut("r", modifiers: [.command,.shift])
                Divider()
                Button("打开调整记录…") { store.openProject() }.disabled(store.busy)
                Button("保存调整记录…") { store.saveProject() }.keyboardShortcut("s").disabled(store.photos.isEmpty)
                Button("导出照片…") { store.showExportOptions = true }.keyboardShortcut("e",modifiers:[.command,.shift]).disabled(store.targets.isEmpty || store.controlsBlocked)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo || store.controlsBlocked)
                Button("重做") { store.redo() }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!store.canRedo || store.controlsBlocked)
            }
            CommandMenu("照片") {
                Button("显示／隐藏原图") { store.showOriginal.toggle() }.keyboardShortcut("\\",modifiers:[])
                Button("保存快照") { store.snapshot() }.keyboardShortcut("k").disabled(store.current == nil)
                Button("移除杂物") { store.inspectorTab = "repair" }.keyboardShortcut("r").disabled(store.current == nil || store.controlsBlocked)
                Button("选择全部照片") { store.selectedIDs = Set(store.photos.map(\.id)) }.keyboardShortcut("a")
            }
        }
    }
}
