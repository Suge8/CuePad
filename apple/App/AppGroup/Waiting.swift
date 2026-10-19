import SwiftUI

/// "等你 N"：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。三端侧栏的 Cue 一行、手机与 iPad 的 Cue 页头、菜单栏面板与小组件用它。
/// "等你"（WORDS.md）的现成样子只有这个文件里的两件（"等你 N"与 iPhone 底部 Cue 圆钮的角标 `WaitingBadge`），加上去 Cue 的入口角上的点（`CueDot`）、状态图形 `Icon.waiting`（经 `PiShown.icon`）与 Agent 页卡片的 `Palette.waitingWash`：
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

/// 角标：赭黄小胶囊里写在等的数，没有在等的不画（iPhone 底部那一排的 Cue 圆钮）。11 起步、跟随字号放大；
/// 上限 xLarge 加在调用处——`@ScaledMetric` 读的是角标外面的字号，加在 body 里限不住它；再大就盖住头像。
struct WaitingBadge: View {
    let count: Int
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 20

    var body: some View {
        if count > 0 {
            Text("\(count)").font(.system(size: size, weight: .bold).monospacedDigit()).foregroundStyle(palette.onFill)
                .contentTransition(.numericText(value: Double(count)))
                .padding(.horizontal, 5).frame(minWidth: diameter, minHeight: diameter)
                .background(palette.waitingFill, in: .capsule)
                .transition(.scale.combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }
}
