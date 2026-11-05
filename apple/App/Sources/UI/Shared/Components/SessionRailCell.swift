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
        .accessibilityValue(Dotted(item.session.agentMark, item.pulse.shown?.label, item.pulse.fullContext?.help.spoken).spoken)
        .accessibilityIdentifier("session-rail-\(item.id)")
        .modifier(CellHelp(form: form, text: help))
    }

    private var help: String { Dotted(item.session.title, item.pulse.shown?.label).visible }

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
                // 宽屏：行首一格是标志与状态记号（线收到格里、两边留纸的内边），名字在右边，收起时淡去、改在悬停提示里
                RailLine(wide: form == .wide) {
                    VStack(spacing: Spacing.hair) {
                        mark.frame(height: 16)
                        signal.frame(width: Chrome.control - 2 * Chrome.pad)
                    }
                } rest: {
                    name.font(Typography.body)
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
            .foregroundStyle(item.pulse.tier == .resting && item.waiting == nil ? palette.ink3 : palette.ink)
            .lineLimit(1)
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

/// 格子的悬停说明：收起的会话条上名字淡去，指针一停名字就浮在格子右边（`railTip`，挂在 `label` 里）；其余照系统的慢提示。
private struct CellHelp: ViewModifier {
    let form: SessionRail.Form
    let text: String

    func body(content: Content) -> some View {
        if form == .narrow { content } else { content.help(text) }
    }
}
