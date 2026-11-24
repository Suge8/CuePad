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
    let selected: Bool
    var compact = false
    let open: (SessionState, SessionRail.Opening) -> Void
    @Environment(\.palette) private var palette
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        control
            .contextMenu { menu }
            .accessibilityActions { menu }
            .contentShape(.dragPreview, .rect(cornerRadius: Radius.row))
            .draggable(DraggedSession(sessionID: item.id))
            .reportsWideDrag(.pane(.session(SessionRoute(id: SessionState.recordID(sessionID: item.id), sessionID: item.id))))
            .padding(.leading, compact ? Self.indent : 0)
            #if os(macOS)
            .overlay(alignment: .topTrailing) {
                if let finishing {
                    RailHoverTool(finishing.title, finishing.icon, action: finishing.run)
                        .padding(.trailing, Spacing.group - RailHoverTool.overhang).padding(.top, Spacing.item - RailHoverTool.overhang / 2)
                        .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .presetHover($hovering)
            .animation(Motion.fade, value: hovering)
            #endif
            .relaySpot(session: item.id, row: .rail)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(live ? Text("\(item.name)，有活预览") : Text(verbatim: item.name))
            .accessibilityValue(Dotted(item.shown.label, project?.shownName, item.session.agentMark, item.pulse.fullContext?.help.spoken).spoken)
            .accessibilityIdentifier("session-rail-\(item.id)")
            .help(help)
    }

    private var running: Bool { item.waiting == nil && item.pulse.tier == .running }

    private var live: Bool {
        #if os(macOS)
        compact && workspace.hasLivePage(item.session.id)
        #else
        false
        #endif
    }

    static let indent: CGFloat = Chrome.icon / 2 + Spacing.tight + RowMetrics.bleed
    static let mark: CGFloat = 12

    private var help: String { Dotted(item.name, project?.shownName, item.shown.label, item.ask ?? item.doing, item.session.agentMark).visible }

    private var project: Project? { workspace.catalog?.project(item.session.projectID ?? Project.defaultID) }

    @ViewBuilder private var control: some View {
        #if os(macOS)
        let button = Button { open(item.session, (NSApp.currentEvent?.modifierFlags.contains(.command) == true) ? .beside : .primary) } label: { label }
        if compact { button.buttonStyle(RowStyle(selected: selected)) } else { button.buttonStyle(PressStyle(.button)) }
        #else
        label
            .row(selected: selected && compact)
            .gesture(SessionTap { open(item.session, $0 ? .beside : .primary) })
            .focusable(interactions: .activate)
            .onKeyPress(.space) { open(item.session, .primary); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(item.session, .primary) }
        #endif
    }

    @ViewBuilder private var menu: some View {
        SessionActions(session: item.session, task: item.task)
    }

    private var label: some View {
        Group {
            if compact {
                RailLine(leadWidth: Self.mark) {
                    ZStack {
                        if running {
                            BoardLaneMark(column: .advancing, size: Self.mark).transition(Motion.pop(reduceMotion: reduceMotion))
                        } else if item.ended {
                            StateGlyph(status: .ended).font(Glyph.small).transition(Motion.pop(reduceMotion: reduceMotion))
                        }
                    }
                    .animation(Motion.fade, value: running)
                    .animation(Motion.fade, value: item.ended)
                } rest: {
                    name.font(Typography.body)
                    Spacer(minLength: Spacing.item)
                    if live { Image(.livePreview).font(Glyph.small).foregroundStyle(palette.ink3).readerHidden(true).transition(.opacity) }
                    SessionRailReadout(item: item)
                }
                .animation(Motion.fade, value: live)
            } else {
                card
            }
        }
        .contentShape(.rect)
    }

    private var finishing: RowAction? {
        #if os(macOS)
        guard hovering, !compact, item.waiting == .awaitsReply else { return nil }
        return SessionActions.complete(item.session, task: item.task, in: workspace)
        #else
        return nil
        #endif
    }

    private var name: some View {
        Text(verbatim: item.name)
            .fontWeight(selected ? .semibold : nil)
            .foregroundStyle(item.ended ? palette.ink3 : item.resting ? palette.ink2 : palette.ink)
            .lineLimit(1)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                if let waiting = item.waiting { StateGlyph(status: waiting).font(Glyph.small).frame(width: 11) }
                name.font(Typography.body)
                Spacer(minLength: 0)
                SessionRailTime(item: item).font(Typography.caption).fixedSize().opacity(finishing == nil ? 1 : 0)
            }
            HStack(spacing: Spacing.tight) {
                if let project {
                    ProjectGlyph(project: project, size: 11)
                    Text(verbatim: project.shownName).foregroundStyle(palette.ink3)
                }
                Spacer(minLength: Spacing.item)
                if let model = item.session.model { Text(verbatim: ModelName.short(model)).foregroundStyle(palette.ink3).layoutPriority(1) }
                if let agent = item.session.agent.known { agent.mark.image.font(Glyph.row).foregroundStyle(palette.ink2).readerHidden(true) }
            }
            .font(Typography.caption)
            .lineLimit(1)
        }
        .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(cornerRadius: Radius.card, lifted: true, wash: TaskBoard.Column.waiting.paper(palette))
        .overlay { if selected { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(palette.ink2, lineWidth: 1.5) } }
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
        if let cache = item.cache, cache.warmUntil != nil {
            Moments(next: cache.nextTick(after:)) { now in
                if let left = cache.minutesLeft(at: now) {
                    (cache.estimated == true ? Text("缓存约 \(left)m 过期") : Text("缓存 \(left)m 过期")).foregroundStyle(palette.ink3).monospacedDigit()
                } else {
                    waited
                }
            }
        } else {
            waited
        }
    }

    @ViewBuilder private var waited: some View {
        if let clock = item.shown.clock {
            LiveText(style: clock.live(.span)) { Text($0).foregroundStyle(palette.ink3).monospacedDigit() }
        }
    }
}

extension SessionRailRows.Item {
    var shown: SessionShown {
        guard let waiting else { return pulse.shown ?? SessionShown(status: .unknown) }
        return SessionShown(status: waiting, clock: pulse.shown?.clock)
    }

    var resting: Bool { waiting == nil && pulse.tier == .resting }

    var ended: Bool { waiting == nil && shown.status == .ended }

    var ask: String? { SessionProgress.firstLine(waiting == .asking ? session.question?.displayText ?? session.detail : session.lastReply) }

    var doing: String? { SessionProgress.firstLine(session.detail) ?? SessionProgress.firstLine(session.lastReply) }
}
