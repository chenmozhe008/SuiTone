// 按进程号找出 App 最大的那个窗口号，配合 screencapture -l 截图验收，不抢用户鼠标。
// 编译：source script/swift_env.sh && swiftc -O script/window_id.swift -o tmp/window_id
// 用法：screencapture -x -o -l $(tmp/window_id $(pgrep -nx SuiTone)) tmp/shot.png
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let largest = windows.max { a, b in
    let ra = a[kCGWindowBounds as String] as! [String: Double], rb = b[kCGWindowBounds as String] as! [String: Double]
    return ra["Width"]! * ra["Height"]! < rb["Width"]! * rb["Height"]!
}
print(largest?[kCGWindowNumber as String] ?? "")
