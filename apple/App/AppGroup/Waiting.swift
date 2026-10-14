import SwiftUI

/// "等你"（WORDS.md）的样子，App 与小组件只此一份：颜色是赭黄，全 App 只有等你用它——它一出现就是"有事要你拍板"。
/// 别的"要你处理"（同步、连接、崩溃）按 `StatusTone.notice` 用墨色，出错是胭脂。赭黄的色值只写在这里，别处写会被源码检查拦下（`lint.sh`）。
/// 表达等你只经这里：会话状态色与 Cue 头像的环取 `tint`，状态图形取 `symbol`；现成的几件是"等你 N"（`WaitingCount`）、
/// iPhone 底栏的角标（`WaitingBadge`）、iPad 工具栏钮上的点（`WaitingDot`）与问题前面的问号（`WaitingMark`）。
/// 颜色只随深浅色变，增强对比度时不变（深浅两档对纸的对比度已够）。
enum Waiting {
    static func tint(dark: Bool) -> Color { Color(hex: dark ? 0xEDBD57 : 0xA8740A) }
    /// 实心问号圆：等你确认的问题与会话状态标同一个图形。
    static let symbol = "questionmark.circle.fill"
}

/// "等你 N"：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。Mac 侧栏、菜单栏面板、iPad 侧栏与小组件用它。
struct WaitingCount: View {
    let count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if count > 0 {
            Text("等你 \(count)").fontWeight(.semibold).monospacedDigit().foregroundStyle(Waiting.tint(dark: scheme == .dark))
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// 角标：赭黄小胶囊里写在等的数，没有在等的不画（iPhone 底栏 Agent 那一格）。比标签字（10）小一档、9 起步，跟随字号放大；
/// 上限 xLarge 加在调用处——`@ScaledMetric` 读的是角标外面的字号，加在 body 里限不住它；再大就盖住图标。
struct WaitingBadge: View {
    let count: Int
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 16

    var body: some View {
        if count > 0 {
            Text("\(count)").font(.system(size: size, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 4).frame(minWidth: diameter, minHeight: diameter)
                .background(Waiting.tint(dark: scheme == .dark), in: .capsule)
                .accessibilityHidden(true)
        }
    }
}

/// 图标右上角的赭黄小点，没有在等的不画（iPad 右侧 Cue 面板的开关）。
struct WaitingDot: View {
    let count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if count > 0 { Circle().fill(Waiting.tint(dark: scheme == .dark)).frame(width: 7, height: 7).offset(x: 3, y: -2) }
    }
}

/// 问题前面的赭黄问号圆（问题卡、Cue 的"等你"），跟着旁边的字号；读屏跳过。
struct WaitingMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: Waiting.symbol).foregroundStyle(Waiting.tint(dark: scheme == .dark)).accessibilityHidden(true)
    }
}
