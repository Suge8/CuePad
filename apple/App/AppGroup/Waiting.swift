import SwiftUI

/// "等你 N"（拍板加待回复，`CueTally.waitingCount`）：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。iPhone 底部那一排的 Cue 钮用它。
/// "等你"（WORDS.md）的现成样子只有这个文件里的"等你 N"，加上 Cue 此刻里赭黄的珠子（`BeadDot`）、去 Cue 的入口角上的点（`CueDot`）、状态图形 `Icon.waiting` 与会话的状态字（经 `PiShown`）：
/// 赭黄只给等你。别的"要你处理"（同步、连接）按 `StatusTone.notice` 用墨色，出错是胭脂圆叹号（`Icon.failure`）。
struct WaitingCount: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        if count > 0 {
            Text("等你 \(count)").fontWeight(.semibold).monospacedDigit().foregroundStyle(palette.waiting)
                .contentTransition(.numericText(value: Double(count)))
                .fixedSize()
                .transition(.opacity)
        }
    }
}
