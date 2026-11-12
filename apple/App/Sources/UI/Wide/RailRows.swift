import CueStore
import SwiftUI


struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) { content }
            .padding(.horizontal, RowMetrics.bleed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RailLine<Lead: View, Rest: View>: View {
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
/// 放在会话条里的都是会话条的一员，不比行首图标重。
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

/// 会话条最上一行：选中时 Cue 铺满会话条之外（`Workspace.goHome`），同手机以 Cue 为根。
struct RailCue: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue, selected = workspace.cueHome
        Button { workspace.goHome() } label: {
            RailLine {
                CueAvatar(cue.beat, size: .inline)
            } rest: {
                Text(verbatim: cue.name).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(verbatim: cue.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 个数与"更早"那一页读同一个查询，两边对得上。
struct RailEarlier: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        let total = total ?? 0
        let selected = workspace.mainRoute == .earlier && !workspace.cueHome
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
            try SessionListData.earlier(SessionQuery(limit: 1), at: moment, from: store).total
        }
    }
}

extension View {
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

