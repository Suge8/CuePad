import CueStore
import SwiftUI

/// 原型会话那一段的容器：分组、注意顺序、等你最多占一半高、接力滚入照 `SessionRail`，不铺纸；行高与组头由 `RailProtoSessions` 给。
/// 行与行之间一道缝（`Spacing.hair`，同去处那一组）。行增删：留下的行按 `Motion.nudge` 让位，进出的行淡入淡出（减弱动态效果时不挪、只淡）。
struct RailProtoGroups<Header: View, Row: View>: View {
    let rows: SessionRailRows
    let wide: Bool
    let marked: Set<String>
    let height: (SessionRailRows.Item) -> CGFloat
    @ViewBuilder let header: (TaskBoard.Column, Int) -> Header
    @ViewBuilder let row: (SessionRailRows.Item, _ moves: Bool, _ selected: Bool) -> Row
    @Environment(Workspace.self) private var workspace
    @Environment(\.relayStage) private var stage
    @Environment(\.pageActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = SessionRailReveal()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: Chrome.groupGap) {
                if !rows.waiting.isEmpty {
                    group(rows.waiting, column: .waiting, moving: [])
                        .frame(height: min(ideal(rows.waiting), geometry.size.height * (rows.advancing.isEmpty ? 1 : 0.5)))
                }
                if !rows.advancing.isEmpty {
                    group(rows.advancing, column: .advancing, moving: rows.moving)
                        .frame(maxHeight: ideal(rows.advancing))
                }
                Spacer(minLength: 0)
            }
        }
        .onChange(of: [rows.waiting.map(\.id), rows.advancing.map(\.id)], initial: true) { _, groups in reveal.update(groups) }
        .onChange(of: active, initial: true) { _, active in reveal.active = active }
        .onAppear { stage?.register(reveal); reveal.active = active }
        .onDisappear { reveal.active = false }
    }

    private func ideal(_ items: [SessionRailRows.Item]) -> CGFloat {
        Chrome.groupHeader + items.map(height).reduce(0, +) + CGFloat(max(0, items.count - 1)) * Spacing.hair + Chrome.pad
    }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column, moving: Set<String>) -> some View {
        VStack(spacing: 0) {
            header(column, items.count).frame(height: Chrome.groupHeader).padding(.horizontal, Chrome.pad)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Spacing.hair) {
                        ForEach(items) { item in
                            let selected = marked.contains(item.id)
                            RailProtoCell(item: item, wide: wide, selected: selected, open: open) { row(item, moving.contains(item.id), selected) }
                                .frame(height: height(item))
                                .id(item.id)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, Chrome.pad)
                    .scrollTargetLayout()
                    .safeAreaPadding(.bottom, Chrome.pad)
                }
                .scrollIndicators(.hidden)
                .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade, value: items.map(\.id))
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { reveal.busy.remove(column) } else { reveal.busy.insert(column) }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 1) { reveal.visible[column] = Set($0) }
                .onAppear {
                    reveal.register(column) { id in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onDisappear { reveal.remove(column) }
            }
        }
        .rowContainer(.rect(cornerRadius: Radius.block))
        .padding(.horizontal, Chrome.edge)
    }

    private func open(_ session: PiSessionState, _ opening: SessionRail.Opening) {
        workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .beside ? .beside : .main)
    }
}

/// 原型里的一个会话：点按、⌘ 点并排、右键菜单、拖到主区、接力落点、读屏照 `SessionRailCell`，长相由各方向给（`label`）。
struct RailProtoCell<Label: View>: View {
    let item: SessionRailRows.Item
    let wide: Bool
    let selected: Bool
    let open: (PiSessionState, SessionRail.Opening) -> Void
    @ViewBuilder let label: Label

    var body: some View {
        control
            .contextMenu { menu }
            .accessibilityActions { menu }
            .contentShape(.dragPreview, .rect(cornerRadius: Radius.row))
            .draggable(DraggedSession(sessionID: item.id))
            .relaySpot(session: item.id, row: .rail)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(item.session.title)
            .accessibilityValue(Dotted(item.shownState.label, item.session.agentMark, item.pulse.fullContext?.help.spoken).spoken)
            .accessibilityIdentifier("session-rail-\(item.id)")
            .help(wide ? help : "")
    }

    private var help: String { Dotted(item.session.title, item.shownState.label, item.session.agentMark).visible }

    private var styled: some View {
        label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
            .railTip(wide ? nil : help)
    }

    @ViewBuilder private var control: some View {
        #if os(macOS)
        Button { open(item.session, (NSApp.currentEvent?.modifierFlags.contains(.command) == true) ? .beside : .primary) } label: { styled }
            .buttonStyle(RowStyle(selected: selected, cell: true))
        #else
        styled
            .row(selected: selected, cell: true)
            .gesture(SessionTap { open(item.session, $0 ? .beside : .primary) })
            .focusable(interactions: .activate)
            .onKeyPress(.space) { open(item.session, .primary); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(item.session, .primary) }
        #endif
    }

    @ViewBuilder private var menu: some View {
        OpenSessionBeside(session: item.session)
        SessionActions(session: item.session)
    }
}

extension SessionRailRows.Item {
    /// 行上画的状态：等你组是拍板或待回复（计时同这个会话），其余同看板（`BoardPulse`）。
    var shownState: PiShown {
        guard let waiting else { return pulse.shown ?? PiShown(status: .unknown()) }
        return PiShown(status: waiting, clock: pulse.shown?.clock)
    }

    var resting: Bool { waiting == nil && pulse.tier == .resting }
}

/// 行尾的读数：要你管的写状态词（同状态色），其余写在这个状态里待了多久。
struct ProtoReadout: View {
    let item: SessionRailRows.Item
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch item.pulse.word {
            case .state(let shown): Text(shown.label).fontWeight(.semibold).foregroundStyle(shown.labelTint(palette))
            case .context(let meter): ContextFact(meter: meter)
            case nil: ProtoTime(item: item)
            }
        }
        .font(Typography.caption)
        .lineLimit(1)
        .fixedSize()
    }
}

/// 在这个状态里待了多久（"刚刚""6 分钟"），淡墨、等宽数字。
struct ProtoTime: View {
    let item: SessionRailRows.Item
    @Environment(\.palette) private var palette

    var body: some View {
        if let clock = item.shownState.clock {
            LiveText(style: clock.live(.span)) { Text($0).foregroundStyle(palette.ink3).monospacedDigit() }
        }
    }
}
