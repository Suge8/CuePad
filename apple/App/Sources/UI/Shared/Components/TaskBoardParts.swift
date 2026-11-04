import CueStore
import SwiftUI

/// 看板的一列（`TaskBoard`；Mac 与宽屏 iPad 四列并排；手机转成一行，四行竖着排，`PhoneBoard`）：身后不铺底（`BoardLane`，拖进来时一层选中底），一件一张卡——
/// 待办、推进中、已完成是任务卡（`BoardTaskCard`）、没绑任务的会话卡（`BoardSessionCard`），等你是一件一张的卡（`BoardWaitCard`，拍板在前、待回复在后），都在懒加载栈里（列可能很长，只建看得见的）。
/// 推进中置顶的在最前，其余按档排（要你管 → 在跑 → 歇着，`Workspace.byAttention`），档与档之间多空一截；在跑的那一档只有前 `BoardLine.maxMoving` 张的线在动，
/// 各卡线上说过的话由列一次读好（`SaidReading`）。
/// 看全部项目时卡上标题前一个项目小图形。点击去处：待办、已完成的卡开任务气泡；推进中的任务卡进此刻干活的会话（没有会话的开气泡），会话卡进会话；
/// 等你的卡只看不答：拍板点了去 Cue 页那一问（会话在问的进会话），待回复进会话。已完成卡尾的成果图点开全屏看（这一列挂一个 `previewPresenter`）。
/// 拖放：行拖到推进中是开始（同"开始"：Mac 交给 Agent，手机浮起发给 Agent 的输入框）、拖到已完成是做完（同点完成圈，还有没完成的子任务、
/// Agent 还在做时先问一句，`TaskCheck`）；待办里拖到一行前面是排序（`TaskBoard.move`），拖进来不改状态。别的拖法不接。
/// 已完成列末尾是"更早做完的 N"：原地展开（它们没进归档，跳去归档页看到的是别的），展开后旁边是"全部归档"。
struct BoardColumn: View {
    let column: TaskBoard.Column
    /// 按项目范围筛过的看板。
    let board: TaskBoard
    /// 待办顶上浮出添加任务那一行（"+ 新任务"）；新任务落在 `newTaskProject`。
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 已完成列末尾"更早做完的"展开着：四列并排时由 `BoardColumns` 持有（它展开了已完成就不是空列，列宽跟着变）；不给时这一列自己记（手机的一行）。
    var earlier: Binding<Bool>?
    #if os(iOS)
    /// 手机竖版看板的一行（`PhoneBoard`）：排成横着滑的一行（`BoardRowLane`）；否则是一列、列头浮在顶上（Mac、宽屏 iPad）。
    var row = false
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.boardMoves) private var moves
    @Environment(\.cardDrags) private var drags
    @State private var ownEarlier = DebugHooks.preset.showsDone
    @State private var targeted = false
    /// 拖到已完成的那件与它这一下（同点完成圈，`taskCheck`）。
    @State private var finishing: TaskBoard.Item?
    @State private var check = TaskCheck()
    /// 点开的成果图（已完成列）。
    @State private var opened: PreviewOpening?

    var body: some View {
        fed
            .cardDrop(isEnabled: column != .waiting, hover: { targeted = $0 != nil && column != .todo }) { card, _ in
                if let task = card.task { drop(task, before: nil) }
            }
            .taskCheck(finishing?.task, subtasks: finishing?.steps, check: $check)
            .modifier(ShotPresenter(column: column, opened: $opened))
            // 有卡飞进来的那一列（行）排在别的列上面：往左、往上飞的卡不从别的列的卡下面钻过去（`boardFlight`）
            .zIndex(moves?.lands(in: board.flights(column)) == true ? 1 : 0)
    }

    /// 推进中这一列的线要的"最近说过的话"（`SaidReading`）。
    @ViewBuilder private var fed: some View {
        if column == .advancing {
            let sessions = board.advancing.compactMap(\.agent?.state.sessionID).sorted()
            lane.modifier(SaidReading(sessions: sessions))
        } else {
            lane
        }
    }

    @ViewBuilder private var lane: some View {
        #if os(iOS)
        if row {
            BoardRowLane(column: column, count: board.count(column), targeted: lit, rewind: adding && column == .todo ? board.todo.first?.id : nil) {
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

    /// 列头浮在卡上，卡从它后面滚过，不在它下沿裁掉（docs/layout.md 沉浸式的栏）：都是一块写字玻璃（Mac 上是 `boardTopRow`）。
    private var columnLane: some View {
        #if os(macOS)
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .boardLane(column)
            .boardTopRow(column: column, count: board.count(column))
            .background { BoardLane(targeted: lit) }
        #else
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
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

    /// 更早做完的展开着没有（给了 `earlier` 读写它，否则这一列自己那一份）。
    private var showsEarlier: Binding<Bool> { earlier ?? $ownEarlier }

    /// 拖着卡停在这一列上：只在有一张卡正被拖着时算（`CardDrags`），拖完不留着底。
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
            .padding(.horizontal, BoardCardMetrics.inset).padding(.vertical, BoardCardMetrics.inset).padding(.bottom, 24)
    }

    @ViewBuilder private var content: some View {
        switch column {
        case .todo:
            // 手机竖版看板里添加那一行横贯在行上（`BoardRowLane.above`），不进格子
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
                            .boardDim(project: work.project)
                            .boardFlight(work.id)
                            .benchSpot(work.id)
                    }
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            ForEach(board.held) { held in
                let card = BoardWaitCard(held: held, project: glyph(workspace.catalog?.project(held.project))).boardFlight(held.id).benchSpot(held.id)
                if let item = held.item { card.boardDraggable(item.id, session: held.session.sessionID) } else { card }
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

    /// 卡上的项目小图形：只看一个项目时不画（范围已经说了）。
    private func glyph(_ project: Project?) -> Project? { workspace.scopedProject == nil ? project : nil }

    private var newTask: some View {
        NewTaskField(project: newTaskProject, choosesProject: true, autofocus: true) { adding = false }
            #if os(macOS)
            .padding(.horizontal, TaskMetrics.cardPadding)
            #else
            .padding(.horizontal, 6)
            #endif
            .paper(cornerRadius: TaskMetrics.cardRadius)
    }

    /// 空列的占位：空列收窄了（`BoardWidths.compact`），一句话在里面居中折行。
    private func empty(_ text: LocalizedStringResource) -> some View {
        Text(text).font(Typography.secondary).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
            .padding(.horizontal, BoardCardMetrics.inset)
            .frame(maxWidth: .infinity, minHeight: isRow ? nil : 64, maxHeight: isRow ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private var earlierToggle: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { showsEarlier.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("更早做完的 \(board.earlier.count)").monospacedDigit()
                    Chevron(.forward).rotationEffect(.degrees(showsEarlier.wrappedValue ? 90 : 0))
                }
                .frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(showsEarlier.wrappedValue ? "已展开" : "已折叠")
            Spacer(minLength: 0)
            if showsEarlier.wrappedValue {
                // 做完的一键收走：归档后不占列表，照样搜得到
                Button { workspace.attempt { try await workspace.archiveCompletedTasks() } } label: {
                    Text("全部归档").frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                    .help("把做完的任务全部归档（置顶的留着）：不占列表，照样搜得到")
            }
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, 4)
        // 手机一行里它占一格：与旁边的空格一样高、字在中间
        .frame(maxHeight: isRow ? .infinity : nil)
    }

    // MARK: 拖放

    private func drop(_ id: UUID, before target: UUID?) {
        guard let item = board.item(id) else { return }
        let fromTodo = board.todo.contains { $0.id == id }
        switch column {
        case .todo:
            guard fromTodo, let move = board.move(id, before: target) else { return }
            workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
        case .advancing:
            if fromTodo { start(item.task) }
        case .done:
            if item.task.status != .done { finish(item) }
        case .waiting:
            break
        }
    }

    private func start(_ task: Card) { workspace.handOff(task) }

    /// 同点完成圈（`Workspace.tap`，确认、停留与写入同 `taskCheck`）。
    private func finish(_ item: TaskBoard.Item) {
        let busy = workspace.next(for: item, shown: workspace.pulse(of: item.agent).shown)?.agentBusy ?? false
        finishing = item
        check = TaskCheck()
        workspace.tap($check, task: item.task, subtasks: item.steps, agentBusy: busy)
    }
}

extension TaskBoard {
    /// 看板上的这件任务（在哪一列都算）。
    func item(_ id: UUID) -> Item? {
        todo.first { $0.id == id } ?? advancing.lazy.compactMap(\.item).first { $0.id == id } ?? held.lazy.compactMap(\.item).first { $0.id == id }
            ?? done.first { $0.id == id } ?? earlier.first { $0.id == id }
    }
}

/// 已完成列点开的成果图（`BoardShot`）：一页只这一列挂全屏预览。
private struct ShotPresenter: ViewModifier {
    let column: TaskBoard.Column
    @Binding var opened: PreviewOpening?

    func body(content: Content) -> some View {
        if column == .done { content.previewPresenter($opened, reply: .cue) } else { content }
    }
}

/// 读推进中一列各会话最近说的几句，交给列里的卡（`boardSaid`）：一列一次读，会话换了才重新订阅，读到的没变不送到界面。
private struct SaidReading: ViewModifier {
    let sessions: [String]
    @State private var said: [String: [Date]]?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content
            .environment(\.boardSaid, said ?? [:])
            .observing(workspace.services.store, id: sessions, into: $said) { [sessions] in try $0.recentSaid(in: sessions, limit: BoardLine.maxSaid) }
    }
}

/// 推进中这一列从上到下的一格：一张卡（`moves`：线可以动，只给在跑那一档的前几张，`BoardLine.maxMoving`），或档与档之间的空。
/// 置顶的几档连成一块，不在中间空开。
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
            let cards = group.work.enumerated().map { AdvancingSlot.work($1, moves: group.tier == .running && $0 < BoardLine.maxMoving) }
            return (gap ? [.gap(pinned: group.pinned, group.tier)] : []) + cards
        }
    }
}
