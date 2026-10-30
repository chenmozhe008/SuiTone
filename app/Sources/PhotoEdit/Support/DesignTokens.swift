import SwiftUI

/// 工具面板里「选中」的统一样子。
///
/// 深色界面下只用一层灰底看不出选没选，所以选中一律用同一个蓝色实底 + 亮边。
/// 刻意只保留一种强调色：选法、添加／减去、裁切比例用的都是它，
/// 不再按语义给不同按钮各配一种颜色——那会看起来像好几个不同层级的按钮。
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

    /// 没选中：所有按钮共用同一块灰底和同一道描边，不许谁比谁亮一点。
    static let idleFill = Color(white: 0.22)
    static let idleBorder = Color.white.opacity(0.08)
}
