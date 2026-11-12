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

/// 宽屏有两种行。等你的两行（`Chrome.tallRow`）：第一行名字与等了多久，第二行是先看哪个要的——哪个项目（图形带项目色）、它要什么、
/// 哪一家 Agent（行尾的小标志）。排在项目下面的一行（`compact`）：项目已经由上一行说了，只有名字与读数。
/// 行首只有一个点、三种样子（`RailDot`）：要你的实心带状态色，在跑的实心靛青，歇着的空心——会话条上只要分得出这三样，细分的状态在读数那个词与会话页里。
struct SessionRailCell: View {
    let item: SessionRailRows.Item
    let form: SessionRail.Form
    let moves: Bool
    let selected: Bool
    var compact = false
    let open: (SessionState, SessionRail.Opening) -> Void
    @Environment(\.palette) private var palette
    @Environment(Workspace.self) private var workspace

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

    private var help: String { Dotted(item.name, project?.shownName, item.shown.label, item.ask ?? item.doing, item.session.agentMark).visible }

    private var project: Project? { workspace.catalog?.project(item.session.projectID) }

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
                    signal.frame(width: 34)
                }
                .padding(.horizontal, Spacing.hair)
                .padding(.vertical, Spacing.tight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RailLine(height: compact ? Chrome.row : Chrome.tallRow) {
                    RailDot(item: item)
                } rest: {
                    if compact {
                        name.font(Typography.body)
                        Spacer(minLength: Spacing.item)
                        SessionRailReadout(item: item)
                    } else {
                        lines
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

    private var lines: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.item) {
                name.font(Typography.body)
                Spacer(minLength: 0)
                if item.waiting == nil { SessionRailReadout(item: item) } else { SessionRailTime(item: item).font(Typography.caption).fixedSize() }
            }
            HStack(spacing: Spacing.tight) {
                if let project { ProjectGlyph(project: project, size: 10) }
                if item.waiting != nil {
                    Text(item.shown.label).fontWeight(.semibold).foregroundStyle(item.shown.labelTint(palette)).fixedSize()
                    if let ask = item.ask {
                        Dot().foregroundStyle(palette.ink3)
                        Text(verbatim: ask).foregroundStyle(palette.ink2)
                    }
                } else {
                    Text(verbatim: Dotted(project?.shownName, item.doing).visible).foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 0)
                if let agent = item.session.agent.known { agent.mark.image.font(Glyph.small).foregroundStyle(palette.ink3).readerHidden(true) }
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

    private var signal: some View {
        Group {
            if let waiting = item.waiting {
                StateGlyph(status: waiting).font(Glyph.small)
            } else {
                BoardLine(pulse: item.pulse, moves: moves, detail: .now)
            }
        }
        .frame(height: WaveStrip.height)
        .readerHidden(true)
    }
}

private struct RailDot: View {
    let item: SessionRailRows.Item
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if item.resting { Circle().strokeBorder(palette.ink3, lineWidth: 1.5) } else { Circle().fill(item.shown.tint(palette)) }
        }
        .frame(width: Self.size, height: Self.size)
        .readerHidden(true)
    }

    private static let size: CGFloat = 8
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

    var ask: String? { Self.firstLine(waiting == .asking ? session.question?.displayText ?? session.detail : session.lastReply) }

    /// 没在等你的会话第二行写的：此刻在做的那一步，没有就是它上一句回答的头一行。
    var doing: String? { Self.firstLine(session.detail) ?? Self.firstLine(session.lastReply) }

    private static func firstLine(_ text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}
