import SwiftUI

// "等你"（WORDS.md）的样子，App 与小组件只此一份：颜色是赭黄（`Palette.waiting`），全 App 只有等你用它——它一出现就是"有事要你拍板"。
// 别的"要你处理"（同步、连接）按 `StatusTone.notice` 用墨色；出错（含崩溃）是胭脂圆叹号（`Icon.failure`）。
// 表达等你只经这里与 `Palette.waiting`：状态图形是 `Icon.waiting`（App 里的状态图形经 `PiShown.icon` 取它）；
// 现成的几件是"等你 N"（`WaitingCount`）、iPhone 底栏的角标（`WaitingBadge`）与 iPad 工具栏钮上的点（`WaitingDot`）。

/// "等你 N"：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。Mac 侧栏、菜单栏面板、iPad 侧栏与小组件用它。
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

/// 角标：赭黄小胶囊里写在等的数，没有在等的不画（iPhone 底栏 Agent 那一格）。比标签字（10）小一档、9 起步，跟随字号放大；
/// 上限 xLarge 加在调用处——`@ScaledMetric` 读的是角标外面的字号，加在 body 里限不住它；再大就盖住图标。
struct WaitingBadge: View {
    let count: Int
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 16

    var body: some View {
        if count > 0 {
            Text("\(count)").font(.system(size: size, weight: .bold).monospacedDigit()).foregroundStyle(palette.onFill)
                .padding(.horizontal, 4).frame(minWidth: diameter, minHeight: diameter)
                .background(palette.waitingFill, in: .capsule)
                .accessibilityHidden(true)
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
