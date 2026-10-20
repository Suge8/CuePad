import SwiftUI

/// "等你 N"：赭黄的字，没有在等的不画。字号随外面（`.font`），这里定字重与等宽数字。手机 Cue 页头面板里等你那一行用它。
/// "等你"（WORDS.md）的现成样子只有这个文件里的三件（"等你 N"、在管与等你那一行 `TallyLabel`、iPhone 底部 Cue 圆钮的角标 `WaitingBadge`），加上去 Cue 的入口角上的点（`CueDot`）、状态图形 `Icon.waiting` 与会话的状态字（经 `PiShown`）：
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

/// "在管 N · 等你 M"（WORDS.md「在管」「等你」，两个数只读 `CueStore.cueTally`）：在管前是靛青的一截流光（`streak`），等你是赭黄问号（`mark`）与赭黄字；
/// 为 0 的那半不写，都为 0 写一句安静的现状。Cue 那一行（三端侧栏、手机与 iPad 的 Cue 页头、菜单栏面板）、小组件与实时活动用它，流光与问号由各端给：
/// App 里流光在 Cue 做事时会动、问号是 `Icon.waiting`，扩展里是静止的流光与 `WidgetIcon.waiting`。字号与在管那半的字色随外面。
struct TallyLabel<Streak: View, Mark: View>: View {
    let managing: Int
    let waiting: Int
    @ViewBuilder var streak: Streak
    @ViewBuilder var mark: Mark
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            if managing > 0 {
                streak.padding(.trailing, 4)
                Text("在管 \(managing)").monospacedDigit().contentTransition(.numericText(value: Double(managing)))
            }
            if managing > 0, waiting > 0 { Dotted.inline }
            if waiting > 0 {
                mark.foregroundStyle(palette.waiting).padding(.trailing, 3)
                Text("等你 \(waiting)").fontWeight(.semibold).monospacedDigit().foregroundStyle(palette.waiting)
                    .contentTransition(.numericText(value: Double(waiting)))
            }
            if managing == 0, waiting == 0 { Text(Self.quiet) }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(managing == 0 && waiting == 0 ? Self.quiet : Dotted(managing > 0 ? "在管 \(managing)" : nil, waiting > 0 ? "等你 \(waiting)" : nil).spoken)
    }

    static var quiet: String { "手上没有事" }
}

/// 在管前那一截靛青流光的静止样子（两头淡出的一小段）：扩展里就是它，App 里 Cue 静着时也是它（会动的在 `TallyStreak`）。
struct StillStreak: View {
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 12

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [palette.signature.opacity(0), palette.signature, palette.signature.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: Self.thickness)
            .accessibilityHidden(true)
    }

    static let thickness: CGFloat = 3
}
