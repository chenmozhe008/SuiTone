import AppKit

/// 验收用：往自己的窗口里注入真实的鼠标拖动，用来验证「裁切框到底能不能拖」。
///
/// 走的是 `NSApp.sendEvent`，和真手按下去走的是同一条路（命中测试 → SwiftUI 手势），
/// 所以能验证手势本身通不通；而用 CGEvent 往外发事件需要系统的辅助功能授权，常常发不出去。
///
/// 用法：`-debugDrag "0.28,0.30,0.55,0.70"`，多个手势用 `;` 隔开，依次执行。
/// 四个数是窗口内容区的比例坐标（左上角为原点）：起点 x、起点 y、终点 x、终点 y。
/// 每一步都把框和当前页打回标准输出，配合启动日志看有没有生效。
enum DebugDrag {
    /// 命令行启动的 App 把 stdout 重定向到文件时是全缓冲的，不刷就看不到日志。
    private static func log(_ text: String) {
        print(text)
        fflush(stdout)
    }

    @MainActor
    static func run(_ spec: String, box: @escaping () -> [Double]?, tab: @escaping () -> String) async {
        // 窗口可能还没 order front，等一会儿再发事件。
        var window: NSWindow?
        for _ in 0..<40 {
            window = NSApp.windows
                .filter({ $0.isVisible && $0.contentView != nil })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window, let content = window.contentView else { log("debugDrag 找不到窗口"); return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))
        log("debugDrag 窗口 key=\(window.isKeyWindow) visible=\(window.isVisible) appActive=\(NSApp.isActive) frame=\(window.frame)")
        // 内容区是左下角原点，比例坐标是左上角原点，换算一下 y。
        let rect = content.frame
        func point(_ fx: Double, _ fy: Double) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * fx, y: rect.maxY - rect.height * fy)
        }
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }

        for part in spec.split(separator: ";") {
            let values = part.split(separator: ",").compactMap { Double($0) }
            guard values.count == 4 else { log("debugDrag 每段应为 4 个数，跳过：\(part)"); continue }
            let start = point(values[0], values[1]), end = point(values[2], values[3])
            log("debugDrag 段 \(part) 框（拖动前）=\(String(describing: box())) 页=\(tab())")
            if let down = event(.leftMouseDown, start) { NSApp.sendEvent(down) }
            for step in 1...12 {
                let t = Double(step) / 12
                let location = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                if let drag = event(.leftMouseDragged, location) { NSApp.sendEvent(drag) }
            }
            if let up = event(.leftMouseUp, end) { NSApp.sendEvent(up) }
            log("debugDrag 段 \(part) 框（拖动后）=\(String(describing: box())) 页=\(tab())")
        }
    }
}

/// 验收用：往窗口里补一个真实按键，验证「回车＝确定」这条路通不通。
/// 和真手一样走 `NSApp.sendEvent`，会先经过 local key monitor，所以能验证兜底逻辑。
enum DebugKey {
    private static func log(_ text: String) {
        print(text)
        fflush(stdout)
    }

    @MainActor
    static func pressReturn(box: @escaping () -> [Double]?, applied: @escaping () -> [Double]?, tab: @escaping () -> String) async {
        var window: NSWindow?
        for _ in 0..<40 {
            window = NSApp.windows
                .filter({ $0.isVisible && $0.contentView != nil })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window else { log("debugKey 找不到窗口"); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        log("debugKey 回车前 页=\(tab()) 框=\(String(describing: box())) 已写入=\(String(describing: applied()))")
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else {
            log("debugKey 造不出回车事件"); return
        }
        NSApp.sendEvent(event)
        try? await Task.sleep(for: .milliseconds(800))
        log("debugKey 回车后 页=\(tab()) 框=\(String(describing: box())) 已写入=\(String(describing: applied()))")
    }
}
