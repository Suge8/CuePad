import SwiftUI

/// "等你 N"：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。三端侧栏的 Cue 一行、手机与 iPad 的 Cue 页头、菜单栏面板与小组件用它。
/// "等你"（WORDS.md）的现成样子只有这一件，加上去 Cue 的入口角上的点（`CueDot`）、状态图形 `Icon.waiting` 与会话的状态字（经 `PiShown`）：
/// 赭黄只给等你。别的"要你处理"（同步、连接）按 `StatusTone.notice` 用墨色，出错是胭脂圆叹号（`Icon.failure`）。
struct WaitingCount: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 {
            Text("等你 \(count)").fontWeight(.semibold).monospacedDigit().foregroundStyle(palette.waiting)
                // 数变了数字滚过去（动画由外面给），不两个数叠着淡
                .contentTransition(.numericText(value: Double(count)))
                .fixedSize()
                .transition(.opacity)
        }
    }
}
