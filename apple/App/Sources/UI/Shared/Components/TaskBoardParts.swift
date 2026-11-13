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
    /// 待办里拖着的卡会落在第几张之前（`TaskBoard.slots` 里离指针最近的一处）；各卡的位置只在拖着时有。
    @State private var slot: Int?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var finishing: TaskBoard.Item?
    @State private var check = TaskCheck()
    @State private var opened: PreviewOpening?
    /// 等你列摊开的是哪张；没点过、或点的那张答完走了，就是最前一张（等得最久的）。
    @State private var focal: String?
    #if os(iOS)
    /// 手机那一行是横着滑的，更早做完的几百条排不进去：点了另出一页竖着列。
    @State private var listsEarlier = false
    #endif

    var body: some View {
        lane
            #if os(iOS)
            .sheet(isPresented: $listsEarlier) { earlierList }
            #endif
            .overlay(alignment: .topLeading) { if lit, let slot, let at = position(of: slot) { mark(at: at).transition(.opacity) } }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: slot)
            .coordinateSpace(.named(space))
            // 一列只这一个落点：卡上不另挂（里外两层互相抢，线与底时有时无）。不接的卡（`accepts`）拖过来不亮、不画线，放下也不动
            .cardDrop(isEnabled: drags?.current.map(accepts) == true, hover: { point in
                targeted = point != nil
                slot = point.flatMap(slot)
            }) { card, point in
                if let task = card.task { drop(task, at: slot(at: point)) }
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
            .boardTopRow(column: column, count: board.count(column), archives: archives, targeted: lit)
        #else
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .modifier(LaneAnchor(column, rewind: rewind))
            .boardLane(column)
            .safeAreaPadding(.top, BoardColumnHeader.height + BoardCardMetrics.inset)
            .overlay(alignment: .top) {
                BoardColumnHeader(column: column, count: board.count(column), archives: archives)
                    .padding(.horizontal, TaskMetrics.cardPadding)
                    .glass(in: .rect(cornerRadius: TaskMetrics.cardRadius))
                    .padding([.horizontal, .top], BoardCardMetrics.inset)
            }
            .background { BoardLane(targeted: lit) }
        #endif
    }

    private var archives: Bool { column == .done && !(board.done.isEmpty && board.earlier.isEmpty) }

    /// 打开添加任务时待办回到开头（行滑到首格，列滚回顶）：添加那一行在待办最前，滚过的列要把它带进视野。
    private var rewind: UUID? { adding && column == .todo ? board.todo.first?.id : nil }

    private var showsEarlier: Binding<Bool> { earlier ?? $ownEarlier }

    /// 接得住的卡拖到这一列上就亮；待办另画一条线说落在哪（`slot`）。
    private var lit: Bool { targeted && drags?.current.map(accepts) == true }

    private var space: String { "board-lane-\(column)" }

    private func loose(_ session: String) -> SessionListItem? {
        (board.advancing.compactMap(\.loose) + board.held.filter { $0.item == nil }.map { SessionListItem(state: $0.session) }).first { $0.state.sessionID == session }
    }

    /// 放下会不会有事发生，与 `drop` 的两个分支一一对应。
    private func accepts(_ card: DraggedCard) -> Bool {
        switch (column, card) {
        case (.waiting, _), (_, .idea), (.advancing, .session): false
        // 推进中的任务拖回待办；待办里的换位置
        case (.todo, .task(let id)): board.advancing.contains { $0.item?.id == id } || !board.slots(for: id).isEmpty
        case (.advancing, .task(let id)): board.todo.contains { $0.id == id }
        case (.done, .task(let id)): board.item(id).map { $0.task.status != .done } ?? false
        case (.todo, .session(let id)): loose(id)?.state.canEnd == true
        case (.done, .session(let id)): loose(id) != nil
        }
    }

    /// 手机的行是横着排的一条，按横向算。
    private func along(_ point: CGPoint) -> CGFloat { isRow ? point.x : point.y }

    private func slot(at point: CGPoint) -> Int? {
        guard column == .todo, let id = drags?.current?.task else { return nil }
        let at = along(point)
        return board.slots(for: id).compactMap { slot in position(of: slot).map { (slot, abs($0 - at)) } }.min { $0.1 < $1.1 }?.0
    }

    /// 两张卡之间那道缝的正中；没排出来的卡（滚出去很远的）没有位置。
    private func position(of slot: Int) -> CGFloat? {
        func frame(_ index: Int) -> CGRect? { board.todo.indices.contains(index) ? frames[board.todo[index].id] : nil }
        let half = gap / 2
        switch (frame(slot - 1), frame(slot)) {
        case let (before?, after?): return isRow ? (before.maxX + after.minX) / 2 : (before.maxY + after.minY) / 2
        case let (before?, nil): return (isRow ? before.maxX : before.maxY) + half
        case let (nil, after?): return (isRow ? after.minX : after.minY) - half
        case (nil, nil): return nil
        }
    }

    private var gap: CGFloat {
        #if os(iOS)
        row ? BoardRowMetrics.gap : BoardCardMetrics.gap
        #else
        BoardCardMetrics.gap
        #endif
    }

    @ViewBuilder private func mark(at position: CGFloat) -> some View {
        if isRow {
            Capsule().fill(palette.signature).frame(width: 3).padding(.vertical, Spacing.item).offset(x: position - 1.5).allowsHitTesting(false)
        } else {
            InsertionMark().padding(.horizontal, BoardCardMetrics.inset).offset(y: position - InsertionMark.ring / 2).allowsHitTesting(false)
        }
    }

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
                card(item).boardDraggable(item.id, session: item.agent?.state.sessionID).boardSlot(item.id, in: space, frames: $frames)
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
        NewTaskField(project: newTaskProject, choosesProject: true, stacked: !isRow, autofocus: true) { adding = false }
            .padding(.horizontal, isRow ? Spacing.tight : TaskMetrics.cardPadding)
            .paper(cornerRadius: TaskMetrics.cardRadius, lifted: !isRow)
    }

    /// 能添东西的列空着时，这一格就是添加的入口（列头那颗"+"的同一个动作）；手机的行里添加在行脊上，这一格只是说明。
    @ViewBuilder private func empty(_ text: LocalizedStringResource) -> some View {
        if !isRow, let add = LaneAdd.of(column, in: workspace) {
            Button(action: add.action) {
                vacancy(text) { Label(add.title, icon: .add).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink2) }
                    .contentShape(.rect)
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
                #if os(iOS)
                if row { listsEarlier = true; return }
                #endif
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
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, Spacing.tight)
        .frame(maxHeight: isRow ? .infinity : nil)
    }

    #if os(iOS)
    private var earlierList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BoardCardMetrics.gap) {
                HStack {
                    Text("更早做完的 \(board.earlier.count)").font(Typography.bodyStrong).monospacedDigit()
                    Spacer(minLength: Spacing.item)
                    let archive = LaneAdd.archive(in: workspace)
                    Button(archive.title) { listsEarlier = false; archive.action() }
                    .font(Typography.secondary)
                }
                .padding(.vertical, Spacing.item)
                ForEach(board.earlier) { card($0) }
            }
            .padding(Spacing.inset)
        }
        .background(palette.desk)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    #endif

    private func drop(_ id: UUID, at slot: Int?) {
        guard let item = board.item(id) else { return }
        let fromTodo = board.todo.contains { $0.id == id }
        switch column {
        case .todo:
            let move = slot.flatMap { board.move(id, before: board.todo.indices.contains($0) ? board.todo[$0].id : nil) }
            if fromTodo {
                guard let move else { return }
                workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
            } else if board.advancing.contains(where: { $0.item?.id == id }) {
                // 推进中的任务拖回待办：算没开始（它的会话照旧活着，解开后单独一张留在推进中），落在线画的那个位置；
                // 没有线时（它那个项目在待办里一张都没有）落在项目排到的地方。
                // 等你的不接：那一列按会话在不在问你分，改了状态也还在那儿
                workspace.perform {
                    try await $0.setStatus(id, .todo)
                    if let move { try await $0.moveCard(id, to: move.slot, after: move.after) }
                }
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
        guard let agent = loose(id) else { return }
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
