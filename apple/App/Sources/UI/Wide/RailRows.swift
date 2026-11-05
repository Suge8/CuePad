import CueStore
import SwiftUI

// 会话条上的行（`WideRail` 的去处一组、`SessionRail` 的每个会话都是 `RailLine`）与会话条里的小钮。尺寸只在 `Chrome`。

/// 会话条上的一组行（去处）：行与行之间一道缝（`Spacing.hair`，同各组的会话），行的框让出行底向两边伸出的那一截。
struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) { content }
            .padding(.horizontal, RowMetrics.bleed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 会话条上的一行：行首图标那一列（`Chrome.icon` 宽：图标或状态标），右边隔一档是名字与读数（`rest`）。
struct RailLine<Lead: View, Rest: View>: View {
    /// 等你组的会话高一档（`Chrome.tallRow`）。
    var height = Chrome.row
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest

    var body: some View {
        HStack(spacing: Spacing.item) {
            lead.frame(width: Chrome.icon)
            HStack(spacing: Spacing.glyph) { rest }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .contentShape(.rect)
    }
}

/// 项目、进展：图标与名字的一行。
struct RailRow: View {
    let title: LocalizedStringResource
    let icon: Icon
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            RailLine {
                Image(icon).font(Glyph.control).foregroundStyle(palette.signature)
            } rest: {
                Text(title).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(iOS)
/// iPad 会话条顶上那一排的图标钮（`RailTopTools`）：一格（`Chrome.control` 见方），悬停、按下是这一格的淡底。
struct RailIcon: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: Chrome.control, height: Chrome.control)
                .contentShape(.rect)
        }
        .buttonStyle(RowStyle(cell: true))
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}
#endif

#if os(macOS)
/// 会话条最底下的图标钮（技能与规则、设置）：同开合钮一种无底、悬停才浮一圈淡底的钮（`PressStyle(.button)`，圆同红绿灯一个分量），
/// 图标同会话条上别的行首图标（`Glyph.control`、次一档的墨）：放在会话条里的都是会话条的一员，不比行首图标重。
struct RailTool: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: ControlSize.compact.height, height: ControlSize.compact.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}
#endif

/// 会话条上的"更早"：已结束的会话（`PiSessionList.earlier`，正在唤醒的在推进中；已结束的只在这里与搜索），排在去处一组的进展下面、同一种行，写个数。
/// 点它在主区打开"更早"那一页（`Route.earlier`，`EarlierPage`，三端同一页）；个数与那一页读同一个查询，两边对得上。没有已结束的会话时置灰。
struct RailEarlier: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        let total = total ?? 0
        let selected = workspace.mainRoute == .earlier
        Button { workspace.show(.earlier) } label: {
            RailLine {
                Image(.session).font(Glyph.control).foregroundStyle(palette.signature)
            } rest: {
                Text("更早").font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Text(total, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .disabled(total == 0)
        .accessibilityLabel(Text("更早"))
        .accessibilityValue(Text(total, format: .number))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try PiSessionList.earlier(PiSessionQuery(limit: 1), at: moment, from: store).total
        }
    }
}

extension View {
    /// 会话条的开合钮（Mac 的 `SidebarToggle`、iPad 顶上那一排的侧栏钮）在会话条没露着时角上一颗点：有要拍板的是赭黄，只有待回复的是墨色；
    /// 数只读 `CueNow.Tally`（同 Cue 的名牌与 App 图标的角标，不另算）。会话条露着时等你那一组就在眼前，不画。
    func railWaitingDot(hidden railHidden: Bool) -> some View { modifier(RailWaitingDot(railHidden: railHidden)) }
}

private struct RailWaitingDot: ViewModifier {
    let railHidden: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 点压在圆的右上角外沿上（圆心约在圆框的内切点）。
    private static let shift: CGFloat = Spacing.hair

    func body(content: Content) -> some View {
        let tally = workspace.cue.now.tally
        let dot: Color? = !railHidden ? nil : tally.asks > 0 ? palette.waiting : tally.reply > 0 ? palette.ink : nil
        content
            .overlay(alignment: .topTrailing) {
                if let dot { StatusDot(color: dot, rim: palette.desk).offset(x: Self.shift, y: -Self.shift).transition(Motion.pop(reduceMotion: reduceMotion)) }
            }
            .animation(Motion.fade, value: dot)
            .accessibilityValue(dot == nil ? Text("") : Text("等你 \(tally.needsYou)"))
    }
}

