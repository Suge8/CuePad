import CueStore
import SwiftUI
import UniformTypeIdentifiers

/// 系统拖放只携带会话身份，不携带页面或选边状态；不提供纯文本表示，避免回复框把会话 id 当作用户输入。
nonisolated struct DraggedSession: Codable, Hashable, Sendable, Transferable {
    let sessionID: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .cuepadSession) }
}

extension UTType {
    nonisolated static let cuepadSession = UTType(exportedAs: "\(AppIdentity.id).session", conformingTo: .data)
}

/// 会话条上的一个会话。手机：Agent 标志、名字、状态线竖排在一格里。宽屏（`SessionRail` 头注释）：行首是状态标（`PiStateDot`，全 App 同一份图形），
/// Agent 标志不占行首（同一家的都一样）、在悬停提示与读屏里。
/// - 推进中一行：名字，行尾一个读数——要你管的写状态词（同状态色，`BoardPulse.word`），其余写在这个状态里待了多久（淡墨等宽）；
/// - 等你组两行：名字与等了多久一行，下面一行写它要什么——状态词着状态色，后面是要你拍板的问题原文或留给你回的那句。
///   这一行一直占着（没有原文时只写状态词），整组行高一律、不随状态跳。
/// 选中只有中性底与半粗字（`RowStyle`）；名字墨色，歇着的淡一档。
struct SessionRailCell: View {
    let item: SessionRailRows.Item
    let form: SessionRail.Form
    let moves: Bool
    let selected: Bool
    let open: (PiSessionState, SessionRail.Opening) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if form == .phone {
                control
            } else {
                control
                    .contextMenu { menu }
                    .accessibilityActions { menu }
                    .contentShape(.dragPreview, .rect(cornerRadius: Radius.row))
                    .draggable(DraggedSession(sessionID: item.id))
            }
        }
        .relaySpot(session: item.id, row: .rail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(item.session.title)
        .accessibilityValue(Dotted(item.shown.label, item.session.agentMark, item.pulse.fullContext?.help.spoken).spoken)
        .accessibilityIdentifier("session-rail-\(item.id)")
        .modifier(CellHelp(form: form, text: help))
    }

    private var help: String { Dotted(item.session.title, item.shown.label, item.session.agentMark).visible }

    @ViewBuilder private var control: some View {
        #if os(macOS)
        Button { open(item.session, (NSApp.currentEvent?.modifierFlags.contains(.command) == true) ? .beside : .primary) } label: { label }
            .buttonStyle(RowStyle(selected: selected, cell: true))
        #else
        if form == .phone {
            Button { open(item.session, .primary) } label: { label }
                .buttonStyle(RowStyle(selected: selected))
        } else {
            label
                .row(selected: selected, cell: true)
                .gesture(SessionTap { open(item.session, $0 ? .beside : .primary) })
                .focusable(interactions: .activate)
                .onKeyPress(.space) { open(item.session, .primary); return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(item.session, .primary) }
        }
        #endif
    }

    /// 会话的菜单，同会话出现的每一处。
    @ViewBuilder private var menu: some View {
        OpenSessionBeside(session: item.session)
        SessionActions(session: item.session)
    }

    private var label: some View {
        Group {
            if form == .phone {
                VStack(spacing: Spacing.hair) {
                    mark.frame(height: 16)
                    name.font(Typography.caption2)
                    signal.frame(width: 34)
                }
                .padding(.horizontal, Spacing.hair)
                .padding(.vertical, Spacing.tight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RailLine(wide: form == .wide, height: item.waiting == nil ? Chrome.control : Chrome.tallRow) {
                    PiStateDot(shown: item.shown, size: Chrome.railMark)
                } rest: {
                    if item.waiting == nil {
                        name.font(Typography.body)
                        Spacer(minLength: Spacing.item)
                        SessionRailReadout(item: item)
                    } else {
                        asking
                    }
                }
            }
        }
        .contentShape(.rect)
        // 挂在行底以内：读的是这一行的悬停（`rowHovered`）
        .railTip(form == .narrow ? help : nil)
    }

    private var name: some View {
        Text(verbatim: item.session.title)
            .fontWeight(selected ? .semibold : nil)
            .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
            .lineLimit(1)
    }

    /// 等你组的两行：名字与等了多久，下面它要什么。
    private var asking: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.item) {
                name.font(Typography.body)
                Spacer(minLength: 0)
                SessionRailTime(item: item).font(Typography.caption).fixedSize()
            }
            HStack(spacing: Spacing.tight) {
                Text(item.shown.label).fontWeight(.semibold).foregroundStyle(item.shown.labelTint(palette)).fixedSize()
                if let ask = item.ask {
                    Dot().foregroundStyle(palette.ink3)
                    Text(verbatim: ask).foregroundStyle(palette.ink2)
                }
            }
            .font(Typography.caption)
            .lineLimit(1)
        }
    }

    private var mark: some View {
        Group {
            if let agent = item.session.agent.known { agent.mark.image } else { Image(.terminal) }
        }
        .font(Glyph.control)
        .foregroundStyle(palette.ink2)
        .accessibilityHidden(true)
    }

    private var signal: some View {
        Group {
            if let waiting = item.waiting {
                PiStateGlyph(status: waiting).font(Glyph.small)
            } else {
                BoardLine(pulse: item.pulse, moves: moves, detail: .now)
            }
        }
        .frame(height: WaveStrip.height)
        .accessibilityHidden(true)
    }
}

/// 推进中一行行尾的读数：要你管的写状态词（同状态色、半粗），其余写在这个状态里待了多久。
private struct SessionRailReadout: View {
    let item: SessionRailRows.Item
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch item.pulse.word {
            case .state(let shown): Text(shown.label).fontWeight(.semibold).foregroundStyle(shown.labelTint(palette))
            case .context(let meter): ContextFact(meter: meter)
            case nil: SessionRailTime(item: item)
            }
        }
        .font(Typography.caption)
        .lineLimit(1)
        .fixedSize()
    }
}

/// 在这个状态里待了多久（"刚刚""6 分钟"，`PiClock.Style.span`）：淡墨、等宽数字，经 `LiveText` 只在字会变的那一刻重画。
private struct SessionRailTime: View {
    let item: SessionRailRows.Item
    @Environment(\.palette) private var palette

    var body: some View {
        if let clock = item.shown.clock {
            LiveText(style: clock.live(.span)) { Text($0).foregroundStyle(palette.ink3).monospacedDigit() }
        }
    }
}

extension SessionRailRows.Item {
    /// 行上画的状态：等你组是拍板或待回复（计时同这个会话），其余同看板（`BoardPulse`）。
    var shown: PiShown {
        guard let waiting else { return pulse.shown ?? PiShown(status: .unknown()) }
        return PiShown(status: waiting, clock: pulse.shown?.clock)
    }

    /// 歇着：名字淡一档。
    var resting: Bool { waiting == nil && pulse.tier == .resting }

    /// 等你组第二行跟在状态词后面的原文（第一行）：要你拍板的问题，或留给你回的那句。
    var ask: String? {
        let text = waiting == .asking ? session.question?.displayText ?? session.detail : session.lastReply
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}

/// 格子的悬停说明：收起的会话条上名字淡去，指针一停名字就浮在格子右边（`railTip`，挂在 `label` 里）；其余照系统的慢提示。
private struct CellHelp: ViewModifier {
    let form: SessionRail.Form
    let text: String

    func body(content: Content) -> some View {
        if form == .narrow { content } else { content.help(text) }
    }
}
