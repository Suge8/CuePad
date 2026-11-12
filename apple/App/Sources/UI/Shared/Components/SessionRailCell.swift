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

/// 宽屏有两种样子。等你的是一张卡（`card`）：会话条上唯一要你动手的，长得不同于下面的行。排在项目下面的一行（`compact`）：缩进一格，
/// 项目已经由上一行说了，只有名字与读数。
/// 行首不放状态点：只有在推进的画看板推进中那个记号（同项目行尾数的那个），歇着、结束的不画、名字淡一档——没事的不该有记号要人去认。
/// 否决过：每种状态一个图形（七八种，认不过来）；实心、空心的点分在跑与歇着（两种点摆在一起读不出哪个是哪个）；
/// 等你的行首放项目的图形（只看图形认不出是哪个项目，写名字才认得）。
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

    private var besides: Bool {
        guard let main = workspace.session(in: .main) else { return false }
        return main.sessionID != item.id && workspace.besideSession?.sessionID != item.id
    }

    /// 项目下面的会话缩进这么多：行首那一列的中线上画一道引线（`RailProjectSessions`）。
    static let indent: CGFloat = Spacing.group

    private var help: String { Dotted(item.name, project?.shownName, item.shown.label, item.ask ?? item.doing, item.session.agentMark).visible }

    /// 没归项目的会话算在默认项目下（同会话条的分组与历史的查询）。
    private var project: Project? { workspace.catalog?.project(item.session.projectID ?? Project.defaultID) }

    @ViewBuilder private var control: some View {
        #if os(macOS)
        let button = Button { open(item.session, (NSApp.currentEvent?.modifierFlags.contains(.command) == true) ? .beside : .primary) } label: { label }
        // 卡自己有面，不要行的悬停底（它比卡宽出一圈）
        if compact { button.buttonStyle(RowStyle(selected: selected)) } else { button.buttonStyle(PressStyle(.button)) }
        #else
        if form == .phone {
            Button { open(item.session, .primary) } label: { label }
                .buttonStyle(RowStyle(selected: selected))
        } else {
            label
                .row(selected: selected && compact)
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
            } else if compact {
                RailLine {
                    if item.waiting == nil, item.pulse.tier == .running { BoardLaneMark(column: .advancing, size: 12) } else { Color.clear }
                } rest: {
                    name.font(Typography.body)
                    Spacer(minLength: Spacing.item)
                    SessionRailReadout(item: item)
                }
                .padding(.leading, Self.indent)
                #if os(macOS)
                // 并排的看得见的入口（另有 ⌘ 点与右键）：主区开着别的会话时，悬停的行尾露出来
                .hoverReveal(when: besides) {
                    Button("在旁边打开", icon: .rightColumn) { open(item.session, .beside) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                        .help("在旁边打开")
                        .padding(.horizontal, Spacing.tight)
                }
                #endif
            } else {
                card
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

    /// 等你的一张卡：纸色同看板等你那一列的卡，浮起一档。两行：名字与等了多久，左边哪个项目（图形带名字）、右边用的模型与哪家 Agent 的标志；它要你做什么在悬停提示里、点开就是。
    /// 开着的那张描一圈墨边。
    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // 等你确认还是待回复只画行首那个图形（同看板等你那一列的卡），字在悬停提示与读屏里：两张卡各多一行状态字，这一组读着像表单
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                if let waiting = item.waiting { StateGlyph(status: waiting).font(Glyph.small).frame(width: 11) }
                name.font(Typography.body)
                Spacer(minLength: 0)
                SessionRailTime(item: item).font(Typography.caption).fixedSize()
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

    /// 等你的卡：提示缓存还热着就写它还有几分钟过期（这之前回不用原价重读整段上下文，是现在回的理由），过期了才写等了多久。
    var body: some View {
        if let until = item.cache?.warmUntil {
            Moments(next: { Self.left(until, at: $0).map { until.addingTimeInterval(-Double($0 - 1) * 60) } }) { now in
                if let left = Self.left(until, at: now) {
                    (item.cache?.estimated == true ? Text("缓存约 \(left)m 过期") : Text("缓存 \(left)m 过期")).foregroundStyle(palette.ink3).monospacedDigit()
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

    /// 还剩几分钟（往上取整，至少 1）；过期了为 nil。
    private static func left(_ until: Date, at now: Date) -> Int? {
        let seconds = until.timeIntervalSince(now)
        return seconds > 0 ? Int((seconds / 60).rounded(.up)) : nil
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
