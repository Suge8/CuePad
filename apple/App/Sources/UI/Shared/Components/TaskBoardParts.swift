import CueStore
import SwiftUI

/// 不归没做完的事的会话卡只接拖到已完成：它本来就在推进中，拖到待办按列的投影会弹回来，所以不接。
/// 已完成列末尾的"更早做完的 N"原地展开：它们没进归档，跳去归档页看到的是别的。
struct BoardColumn: View {
    let column: TaskBoard.Column
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 已完成列末尾"更早做完的"展开着：四列并排时由 `BoardColumns` 持有（它展开了已完成就不是空列，列宽跟着变）；不给时这一列自己记（手机的一行）。
    var earlier: Binding<Bool>?
    #if os(iOS)
    var row = false
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.boardMoves) private var moves
    @Environment(\.cardDrags) private var drags
    @State private var ownEarlier = DebugHooks.preset.showsDone
    @State private var targeted = false
    @State private var finishing: TaskBoard.Item?
    @State private var check = TaskCheck()
    @State private var opened: PreviewOpening?
    /// 等你列摊开的是哪张；没点过、或点的那张答完走了，就是最前一张（等得最久的）。
    @State private var focal: String?

    var body: some View {
        lane
            .cardDrop(isEnabled: column != .waiting, hover: { targeted = $0 != nil && column != .todo }) { card, _ in
                if let task = card.task { drop(task, before: nil) }
                if let session = card.session { drop(session: session) }
            }
            .taskCheck(finishing?.task, subtasks: finishing?.steps, check: $check)
            .modifier(ShotPresenter(column: column, opened: $opened))
            // 有卡飞进来的那一列（行）排在别的列上面：往左、往上飞的卡不从别的列的卡下面钻过去（`boardFlight`）
            .zIndex(moves?.lands(in: board.flights(column)) == true ? 1 : 0)
    }


    @ViewBuilder private var lane: some View {
        #if os(iOS)
        if row {
            BoardRowLane(column: column, count: board.count(column), targeted: lit, rewind: rewind) {
                if adding && column == .todo { newTask.transition(.opacity) }
            } content: {
                content
            }
        } else {
            columnLane
        }
        #else
        columnLane
        #endif
    }

    /// 列头浮在卡上，卡从它后面滚过，不在它下沿裁掉。
    private var columnLane: some View {
        #if os(macOS)
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column, rewind: rewind))
            .boardLane(column)
            .boardTopRow(column: column, count: board.count(column))
            .background { BoardLane(targeted: lit) }
        #else
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column, rewind: rewind))
            .boardLane(column)
            .safeAreaPadding(.top, BoardColumnHeader.height + BoardCardMetrics.inset)
            .overlay(alignment: .top) {
                BoardColumnHeader(column: column, count: board.count(column))
                    .padding(.horizontal, TaskMetrics.cardPadding)
                    .glass(in: .rect(cornerRadius: TaskMetrics.cardRadius))
                    .padding([.horizontal, .top], BoardCardMetrics.inset)
            }
            .background { BoardLane(targeted: lit) }
        #endif
    }

    /// 打开添加任务时待办回到开头（行滑到首格，列滚回顶）：添加那一行在待办最前，滚过的列要把它带进视野。
    private var rewind: UUID? { adding && column == .todo ? board.todo.first?.id : nil }

    private var showsEarlier: Binding<Bool> { earlier ?? $ownEarlier }

    private var lit: Bool { targeted && drags?.current != nil }

    private var isRow: Bool {
        #if os(iOS)
        row
        #else
        false
        #endif
    }

    private var cards: some View {
        LazyVStack(alignment: .leading, spacing: BoardCardMetrics.gap) { content }
            .scrollTargetLayout()
            .padding(.horizontal, BoardCardMetrics.inset).padding(.vertical, BoardCardMetrics.inset).padding(.bottom, Spacing.section)
    }

    @ViewBuilder private var content: some View {
        switch column {
        case .todo:
            if adding, !isRow {
                newTask.transition(.opacity)
            }
            ForEach(board.todo) { item in
                card(item).boardDraggable(item.id, session: item.agent?.state.sessionID).insertsBefore(item.id) { drop($0, before: item.id) }
            }
            if board.todo.isEmpty && !adding { empty("没有待办") }
        case .advancing:
            // 一个 ForEach 排完各档：卡换档是同一串里换位（让位），不是这一档删一张、那一档添一张（同一个飞行身份一删一添会从栈顶飞过来）
            ForEach(AdvancingSlot.slots(workspace.byAttention(board.advancing), gaps: !isRow)) { slot in
                switch slot {
                case .gap:
                    // 档与档之间多空一截：栈里一格零高的空，前后各一个行距（横着的一行里一格就是一张卡宽，不空）
                    Color.clear.frame(height: 0)
                case .work(let work, let moves):
                    if let item = work.item {
                        card(item, moves: moves).boardDraggable(item.id, session: item.agent?.state.sessionID)
                    } else if let agent = work.loose {
                        BoardSessionCard(agent: agent, project: glyph(workspace.catalog?.project(work.project)), moves: moves)
                            .boardDraggable(session: agent.state.sessionID)
                            .boardDim(project: work.project)
                            .boardFlight(work.id)
                            .benchSpot(work.id)
                    }
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            let open = board.held.contains { $0.id == focal } ? focal : board.held.first?.id
            ForEach(board.held) { held in
                let card = BoardWaitCard(held: held, project: glyph(workspace.catalog?.project(held.project)), focal: held.id == open) {
                    withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { focal = held.id }
                } openShot: { opened = $0 }
                .boardFlight(held.id).benchSpot(held.id)
                if let item = held.item { card.boardDraggable(item.id, session: held.session.sessionID) } else { card.boardDraggable(session: held.session.sessionID) }
            }
            if board.count(.waiting) == 0 { empty("没有等你的事") }
        case .done:
            ForEach(board.done) { card($0) }
            // 列头的数只数今天的：今天没有时先说没有，再接更早的，数与字对得上
            if board.done.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty { earlierToggle }
            if showsEarlier.wrappedValue { ForEach(board.earlier) { card($0) } }
        }
    }

    private func card(_ item: TaskBoard.Item, moves: Bool = false) -> some View {
        BoardTaskCard(item: item, column: column, project: glyph(item.project), moves: moves) { opened = $0 }
            .boardDim(project: item.task.projectID)
            .boardFlight(item.flight)
            .benchSpot(item.id)
    }

    private func glyph(_ project: Project?) -> Project? { workspace.scopedProject == nil ? project : nil }

    private var newTask: some View {
        NewTaskField(project: newTaskProject, choosesProject: true, autofocus: true) { adding = false }
            #if os(macOS)
            .padding(.horizontal, TaskMetrics.cardPadding)
            #else
            .padding(.horizontal, Spacing.tight)
            #endif
            .paper(cornerRadius: TaskMetrics.cardRadius)
    }

    /// 能添东西的列空着时，这一格就是添加的入口（列头那颗"+"的同一个动作）；手机的行里添加在行脊上，这一格只是说明。
    @ViewBuilder private func empty(_ text: LocalizedStringResource) -> some View {
        if !isRow, let add = LaneAdd.of(column, in: workspace) {
            Button(action: add.action) {
                vacancy(text) { Label(add.title, icon: .add).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink2) }
                    .padding(.vertical, Spacing.group).contentShape(.rect)
            }
            .buttonStyle(PressStyle(.card))
        } else {
            vacancy(text) { EmptyView() }
        }
    }

    private func vacancy(_ text: LocalizedStringResource, @ViewBuilder lead: () -> some View) -> some View {
        VStack(spacing: Spacing.tight) {
            lead()
            Text(text).font(Typography.secondary).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
        }
            .padding(.horizontal, BoardCardMetrics.inset)
            .frame(maxWidth: .infinity, minHeight: isRow ? nil : 64, maxHeight: isRow ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private var earlierToggle: some View {
        HStack(spacing: Spacing.group) {
            Button {
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { showsEarlier.wrappedValue.toggle() }
            } label: {
                HStack(spacing: Spacing.tight) {
                    Text("更早做完的 \(board.earlier.count)").monospacedDigit()
                    Chevron(.forward).rotationEffect(.degrees(showsEarlier.wrappedValue ? 90 : 0))
                }
                .frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(showsEarlier.wrappedValue ? "已展开" : "已折叠")
            Spacer(minLength: 0)
            if showsEarlier.wrappedValue {
                Button { workspace.attempt { try await workspace.archiveCompletedTasks() } } label: {
                    Text("全部归档").frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                    .help("把做完的任务全部归档（置顶的留着）：不占列表，照样搜得到")
            }
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, Spacing.tight)
        .frame(maxHeight: isRow ? .infinity : nil)
    }

    private func drop(_ id: UUID, before target: UUID?) {
        guard let item = board.item(id) else { return }
        let fromTodo = board.todo.contains { $0.id == id }
        switch column {
        case .todo:
            if fromTodo {
                guard let move = board.move(id, before: target) else { return }
                workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
            } else if board.advancing.contains(where: { $0.item?.id == id }) {
                // 推进中的任务拖回待办：算没开始（它的会话照旧活着，解开后单独一张留在推进中）。等你的不接：那一列按会话在不在问你分，改了状态也还在那儿
                workspace.perform { try await $0.setStatus(id, .todo) }
            }
        case .advancing:
            if fromTodo { start(item.task) }
        case .done:
            if item.task.status != .done { finish(item) }
        case .waiting:
            break
        }
    }

    private func drop(session id: String) {
        let loose = board.advancing.compactMap(\.loose) + board.held.filter { $0.item == nil }.map { SessionListItem(state: $0.session) }
        guard let agent = loose.first(where: { $0.state.sessionID == id }) else { return }
        switch column {
        case .done: workspace.attempt { try await workspace.finish(agent) }
        // 没绑任务的会话没有"待办"：拖过去是要它停下，走结束会话那一问（对话留着，再说话就恢复）
        case .todo: if agent.state.canEnd { workspace.sessionAsk = .end(agent.state) }
        case .advancing, .waiting: break
        }
    }

    private func start(_ task: Card) { workspace.handOff(task) }

    private func finish(_ item: TaskBoard.Item) {
        let busy = workspace.next(for: item, shown: workspace.pulse(of: item.agent).shown)?.busySession
        finishing = item
        check = TaskCheck()
        workspace.tap($check, task: item.task, subtasks: item.steps, busy: busy)
    }
}

extension TaskBoard {
    func item(_ id: UUID) -> Item? {
        todo.first { $0.id == id } ?? advancing.lazy.compactMap(\.item).first { $0.id == id } ?? held.lazy.compactMap(\.item).first { $0.id == id }
            ?? done.first { $0.id == id } ?? earlier.first { $0.id == id }
    }
}

/// 一列滚到哪按卡记，不按偏移量：列宽一变（会话条换宽、Cue 收起放回、拖窗口跨阈值），标题重新折行、整列内容变高变矮，
/// 按偏移量留着的话原来看着的那张卡滑出视野。这里记下可视区正中的那张卡（`scrollTargetLayout` 的直接子视图，即各列 `ForEach` 的身份），
/// 内容一变由滚动视图自己把它留在正中（系统的 `scrollPosition`，不读几何回写）。身份的类型随列：待办、已完成是任务（`TaskBoard.Item.id`），
/// 推进中、等你是会话与任务混排的那一份（`AdvancingSlot.id`、`TaskBoard.Held.id`）。
/// 给了 `rewind`（打开添加任务）就滚回顶边：添加那一行插在列顶，留在原来那张卡上它就落在视野上方；回顶边不回首卡，它在首卡之上。
private struct LaneAnchor: ViewModifier {
    let rewind: UUID?
    @State private var position: ScrollPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ column: TaskBoard.Column, rewind: UUID?) {
        self.rewind = rewind
        _position = State(initialValue: column.light ? ScrollPosition(idType: UUID.self) : ScrollPosition(idType: String.self))
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position, anchor: .center)
            .onChange(of: rewind) {
                if rewind != nil { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { position.scrollTo(edge: .top) } }
            }
    }
}

private struct ShotPresenter: ViewModifier {
    let column: TaskBoard.Column
    @Binding var opened: PreviewOpening?

    func body(content: Content) -> some View {
        if column == .done || column == .waiting { content.previewPresenter($opened, reply: .cue) } else { content }
    }
}

private enum AdvancingSlot: Identifiable {
    case gap(pinned: Bool, BoardPulse.Tier)
    case work(TaskBoard.Work, moves: Bool)

    var id: String {
        switch self {
        case .gap(let pinned, let tier): "gap/\(pinned)/\(tier)"
        case .work(let work, _): work.id
        }
    }

    static func slots(_ groups: [(pinned: Bool, tier: BoardPulse.Tier, work: [TaskBoard.Work])], gaps: Bool) -> [AdvancingSlot] {
        groups.enumerated().flatMap { offset, group -> [AdvancingSlot] in
            let gap = gaps && offset > 0 && !(group.pinned && groups[offset - 1].pinned)
            let cards = group.work.enumerated().map { AdvancingSlot.work($1, moves: group.tier == .running && $0 < BoardNow.maxMoving) }
            return (gap ? [.gap(pinned: group.pinned, group.tier)] : []) + cards
        }
    }
}
