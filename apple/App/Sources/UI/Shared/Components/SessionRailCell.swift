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

/// Agent 标志不占行首（同一家的都一样），在悬停提示与读屏里。
/// 等你组第二行一直占着（没有原文时只写状态词），整组行高一律、不随状态跳。
struct SessionRailCell: View {
    let item: SessionRailRows.Item
    let form: SessionRail.Form
    let selected: Bool
    let open: (SessionState, SessionRail.Opening) -> Void
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
        .accessibilityLabel(item.name)
        .accessibilityValue(Dotted(item.shown.label, item.session.agentMark, item.pulse.fullContext?.help.spoken).spoken)
        .accessibilityIdentifier("session-rail-\(item.id)")
        .help(help)
    }

    private var help: String { Dotted(item.name, item.shown.label, item.ask, item.session.agentMark).visible }

    @ViewBuilder private var control: some View {
        #if os(macOS)
        Button { open(item.session, (NSApp.currentEvent?.modifierFlags.contains(.command) == true) ? .beside : .primary) } label: { label }
            .buttonStyle(RowStyle(selected: selected))
        #else
        if form == .phone {
            Button { open(item.session, .primary) } label: { label }
                .buttonStyle(RowStyle(selected: selected))
        } else {
            label
                .row(selected: selected)
                .gesture(SessionTap { open(item.session, $0 ? .beside : .primary) })
                .focusable(interactions: .activate)
                .onKeyPress(.space) { open(item.session, .primary); return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(item.session, .primary) }
        }
        #endif
    }

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
                    StateDot(shown: item.shown, size: Chrome.railMark)
                }
                .padding(.horizontal, Spacing.hair)
                .padding(.vertical, Spacing.tight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RailLine(height: item.waiting == nil ? Chrome.row : Chrome.tallRow) {
                    StateDot(shown: item.shown, size: Chrome.railMark)
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
    }

    private var name: some View {
        Text(verbatim: item.name)
            .fontWeight(selected ? .semibold : nil)
            .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
            .lineLimit(1)
    }

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
        .readerHidden(true)
    }

}

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
        .animation(Motion.fade, value: item.pulse.word)
    }
}

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
    var shown: SessionShown {
        guard let waiting else { return pulse.shown ?? SessionShown(status: .unknown()) }
        return SessionShown(status: waiting, clock: pulse.shown?.clock)
    }

    var resting: Bool { waiting == nil && pulse.tier == .resting }

    var ask: String? {
        let text = waiting == .asking ? session.question?.displayText ?? session.detail : session.lastReply
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}
