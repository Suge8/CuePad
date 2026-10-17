import SwiftUI

/// "等你 N"：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。三端侧栏的 Cue 一行、手机与 iPad 的 Cue 页头、菜单栏面板与小组件用它。
/// "等你"（WORDS.md）的现成样子只有这个文件里的两件，加上状态图形 `Icon.waiting`（经 `PiShown.icon`）与 Agent 页卡片的 `Palette.waitingWash`：
/// 赭黄只给等你。别的"要你处理"（同步、连接）按 `StatusTone.notice` 用墨色，出错是胭脂圆叹号（`Icon.failure`）。
struct WaitingCount: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 {
            Text("等你 \(count)").fontWeight(.semibold).monospacedDigit().foregroundStyle(palette.waiting)
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// 图标右上角的赭黄小点，没有在等的不画（iPad 右侧 Cue 面板的开关）。
struct WaitingDot: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 { Circle().fill(palette.waiting).frame(width: 7, height: 7).offset(x: 3, y: -2) }
    }
}
