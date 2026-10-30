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
    @StateObject private var updates = UpdateChecker()

    var body: some Scene {
        WindowGroup(AppIdentity.windowTitle, id: "workspace") {
            ContentView(store: store)
                .environmentObject(updates)
                .preferredColorScheme(.dark)
                .task { updates.checkIfDue(); await store.start() }
                .onOpenURL { url in
                    if url.pathExtension=="photoedit" {store.openProject(url)}
                    else {store.importURLs([url])}
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.flushLibrary()
                }
        }
        .defaultSize(width: 1360, height: 880)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenu(updates: updates)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.settingsTab = "chat" }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("新建图集…") { store.startFreshWorkspace() }.keyboardShortcut("n")
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
                Divider()
                Button(store.showLibrary ? "隐藏图集栏" : "显示图集栏") { store.showLibrary.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
        Window("关于随心修图", id: "about") {
            AboutView().environmentObject(updates).preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

private struct AboutMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        Button("关于随心修图") { AboutState.shared.tab = .intro; openWindow(id: "about") }
        Button("检查更新…") { updates.checkFromMenu() }
        Button("反馈") { AboutState.shared.tab = .feedback; openWindow(id: "about") }
    }
}
