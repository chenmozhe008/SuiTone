import SwiftUI

/// 工具面板里「选中」的样子。深色界面下只用一层灰色底看不出选没选，
/// 所以选中一律换成带颜色的实底 + 亮边，一眼能分出来。
enum ToolAccent {
    struct Tone {
        var fill: LinearGradient
        var border: Color
        var text: Color
    }

    static let blue = Tone(
        fill: LinearGradient(colors: [Color(red: 0.23, green: 0.50, blue: 0.76),
                                      Color(red: 0.14, green: 0.34, blue: 0.55)],
                             startPoint: .top, endPoint: .bottom),
        border: Color(red: 0.48, green: 0.74, blue: 0.98).opacity(0.95),
        text: Color(red: 0.56, green: 0.79, blue: 1.0))

    static let green = Tone(
        fill: LinearGradient(colors: [Color(red: 0.20, green: 0.53, blue: 0.35),
                                      Color(red: 0.12, green: 0.36, blue: 0.24)],
                             startPoint: .top, endPoint: .bottom),
        border: Color(red: 0.44, green: 0.84, blue: 0.58).opacity(0.9),
        text: Color(red: 0.52, green: 0.88, blue: 0.63))

    static let orange = Tone(
        fill: LinearGradient(colors: [Color(red: 0.70, green: 0.42, blue: 0.14),
                                      Color(red: 0.49, green: 0.28, blue: 0.08)],
                             startPoint: .top, endPoint: .bottom),
        border: Color(red: 0.98, green: 0.70, blue: 0.36).opacity(0.9),
        text: Color(red: 0.99, green: 0.73, blue: 0.42))

    static let idleFill = Color(white: 0.22)
    static let idleBorder = Color.white.opacity(0.08)
}
