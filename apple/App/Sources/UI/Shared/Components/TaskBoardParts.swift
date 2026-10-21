import CueStore
import SwiftUI

/// 四列并排（Mac 任务页、宽屏 iPad）：每列（`BoardColumn`）是一条泳道，列头钉在泳道顶上（`BoardColumnHeader`），卡在下面各自滚动。
/// 列按可见宽四等分，窄到一列放不下 `minColumn` 时整排横向滚动。
struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?

    #if os(macOS)
    private static let minColumn: CGFloat = 230
    #else
    /// 一张卡要放下圈、项目小图形与一行够读的标题：iPad 竖屏放三列多一点，横滑看第四列。
    private static let minColumn: CGFloat = 260
    #endif
    private static let gap: CGFloat = 12

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(TaskBoard.Column.allCases) { column in
                    BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject, titled: true)
                        .containerRelativeFrame(.horizontal) { width, _ in max(Self.minColumn, (width - Self.gap * 3) / 4) }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// 看板的一列（`TaskBoard`；Mac 与宽屏 iPad 四列并排，手机一屏一列）：一条按列上色的泳道（`BoardLane`），一件一张卡——
/// 待办、推进中、已完成是任务卡（`BoardTaskCard`）、没绑任务的会话卡（`BoardSessionCard`），等你是 Cue 的气泡（`BoardWaitCard`），都在懒加载栈里（列可能很长，只建看得见的）。
/// 推进中按档排（要你管 → 在跑 → 歇着，`Workspace.byAttention`），档与档之间多空一截；在跑的那一档只有前 `BoardWave.maxMoving` 张的线在动。
/// 看全部项目时卡上标题前一个项目小图形。点击去处：待办、已完成的卡开任务气泡；推进中的任务卡进此刻干活的会话（没有会话的开气泡），会话卡进会话；
/// 等你卡点抬头去回答的地方。已完成卡尾的成果图点开全屏看（这一列挂一个 `previewPresenter`）。
/// 拖放：行拖到推进中是开始（同"开始"：Mac 交给 Agent，手机浮起发给 Agent 的输入框）、拖到已完成是做完（同点完成圈，还有没完成的步骤、
/// Agent 还在做时先问一句，`TaskCheck`）；待办里拖到一行前面是排序（`TaskBoard.move`），拖进来不改状态。别的拖法不接。
/// 已完成列末尾是"更早做完的 N"：原地展开（它们没进归档，跳去归档页看到的是别的），展开后旁边是"全部归档"。
struct BoardColumn: View {
    let column: TaskBoard.Column
    /// 按项目范围筛过的看板。
    let board: TaskBoard
    /// 待办顶上浮出添加任务那一行（"+ 新任务"）；新任务落在 `newTaskProject`。
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 最上面带列头（四列并排时；手机一屏一列由顶上的分段写列名与数）。
    var titled = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEarlier = DebugHooks.preset.showsDone
    @State private var targeted = false
    /// 拖到已完成的那件与它这一下（同点完成圈，`taskCheck`）。
    @State private var finishing: TaskBoard.Item?
    @State private var check = TaskCheck()
    /// 点开的成果图（已完成列）。
    @State private var opened: PreviewOpening?

    var body: some View {
        VStack(spacing: 0) {
            if titled {
                BoardColumnHeader(column: column, count: board.count(column)).padding(.horizontal, TaskMetrics.cardPadding + BoardCardMetrics.inset)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BoardCardMetrics.gap) { content }
                    .padding(.horizontal, BoardCardMetrics.inset).padding(.top, titled ? 0 : BoardCardMetrics.inset).padding(.bottom, 24)
                    .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: ids)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { BoardLane(column: column, targeted: targeted) }
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, before: nil)
        } isTargeted: { targeted = $0 && column != .todo && column != .waiting }
        .taskCheck(finishing?.task, subtasks: finishing?.steps, check: $check)
        .modifier(ShotPresenter(column: column, opened: $opened))
    }

    private var ids: [String] {
        switch column {
        case .todo: board.todo.map(\.id.uuidString)
        case .advancing: board.advancing.map(\.id)
        case .waiting: board.waiting.map(\.id)
        case .done: board.done.map(\.id.uuidString) + (showsEarlier ? board.earlier.map(\.id.uuidString) : [])
        }
    }

    @ViewBuilder private var content: some View {
        switch column {
        case .todo:
            if adding {
                newTask.transition(Motion.item)
            }
            ForEach(board.todo) { item in
                card(item).draggable(item.id.uuidString).modifier(InsertBefore(id: item.id) { drop($0, before: item.id) })
            }
            if board.todo.isEmpty && !adding { empty("没有待办") }
        case .advancing:
            let groups = workspace.byAttention(board.advancing, agents: agents)
            ForEach(groups, id: \.tier) { group in
                // 档与档之间多空一截：栈里一格零高的空，前后各一个行距
                if group.tier != groups.first?.tier { Color.clear.frame(height: 0) }
                ForEach(Array(group.work.enumerated()), id: \.element.id) { index, work in
                    let moves = group.tier == .running && index < BoardWave.maxMoving
                    if let item = work.item {
                        card(item, moves: moves).draggable(item.id.uuidString)
                    } else if case .session(let session) = work.work {
                        BoardSessionCard(session: session, project: glyph(workspace.catalog?.project(work.project)), moves: moves)
                            .boardDim(project: work.project)
                    }
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            ForEach(board.waiting) { wait in
                if let item = wait.item {
                    BoardWaitCard(wait: wait).draggable(item.id.uuidString)
                } else {
                    BoardWaitCard(wait: wait)
                }
            }
            if board.waiting.isEmpty { empty("没有要你拍板的事") }
        case .done:
            ForEach(board.done) { card($0) }
            if board.done.isEmpty && board.earlier.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty { earlierToggle }
            if showsEarlier { ForEach(board.earlier) { card($0) } }
        }
    }

    private func card(_ item: TaskBoard.Item, moves: Bool = false) -> some View {
        BoardTaskCard(item: item, column: column, project: glyph(item.project), moves: moves) { opened = $0 }
            .boardDim(project: item.task.projectID)
    }

    /// 卡上的项目小图形：只看一个项目时不画（范围已经说了）。
    private func glyph(_ project: Project?) -> Project? { workspace.scopedProject == nil ? project : nil }

    @ViewBuilder private var newTask: some View {
        #if os(macOS)
        NewTaskField(project: newTaskProject, choosesProject: true, autofocus: true)
            .padding(.horizontal, TaskMetrics.cardPadding)
            .paper(radius: TaskMetrics.cardRadius)
        #else
        NewTaskLine(project: newTaskProject, projects: workspace.catalog?.projects) { adding = false }
            .padding(.horizontal, 6)
            .paper(radius: TaskMetrics.cardRadius)
        #endif
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typography.secondary).foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private var earlierToggle: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { showsEarlier.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("更早做完的 \(board.earlier.count)").monospacedDigit()
                    Image(.forward).font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsEarlier ? 90 : 0)).accessibilityHidden(true)
                }
                .frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(showsEarlier ? "已展开" : "已折叠")
            Spacer(minLength: 0)
            if showsEarlier {
                // 做完的一键收走：归档后不占列表，照样搜得到
                Button { workspace.attempt { try await workspace.archiveCompletedTasks() } } label: {
                    Text("全部归档").frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                    .help("把做完的任务全部归档：不占列表，照样搜得到")
            }
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, 4)
    }

    // MARK: 拖放

    private func drop(_ ids: [String], before target: UUID?) -> Bool {
        guard let id = ids.first.flatMap(UUID.init(uuidString:)), let item = board.item(id) else { return false }
        let fromTodo = board.todo.contains { $0.id == id }
        switch column {
        case .todo:
            guard fromTodo else { return false }
            if let move = board.move(id, before: target) {
                workspace.perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
            }
            return true
        case .advancing:
            guard fromTodo else { return false }
            start(item.task)
            return true
        case .done:
            guard item.task.status != .done else { return false }
            finish(item)
            return true
        case .waiting:
            return false
        }
    }

    private func start(_ task: Card) { workspace.handOff(task) }

    /// 同点完成圈（`Workspace.tap`，确认、停留与写入同 `taskCheck`）。
    private func finish(_ item: TaskBoard.Item) {
        let busy = workspace.next(for: item.task, lead: item.leaf, in: workspace.agentLinks, steps: item.steps)?.agentBusy ?? false
        finishing = item
        check = TaskCheck()
        workspace.tap($check, task: item.task, subtasks: item.steps, agentBusy: busy)
    }
}

extension TaskBoard {
    /// 看板上的这件任务（在哪一列都算）。
    func item(_ id: UUID) -> Item? {
        todo.first { $0.id == id } ?? advancing.lazy.compactMap(\.item).first { $0.id == id } ?? waiting.lazy.compactMap(\.item).first { $0.id == id }
            ?? done.first { $0.id == id } ?? earlier.first { $0.id == id }
    }
}

/// 已完成列点开的成果图（`BoardShot`）：一页只这一列挂全屏预览。
private struct ShotPresenter: ViewModifier {
    let column: TaskBoard.Column
    @Binding var opened: PreviewOpening?

    func body(content: Content) -> some View {
        if column == .done { content.previewPresenter($opened) } else { content }
    }
}

/// 待办里一张卡的落点：拖到它上面就是排到它前面，卡的上沿画一条插入线（同大纲的插入线：墨色、起点一个小圈）。
private struct InsertBefore: ViewModifier {
    let id: UUID
    let perform: ([String]) -> Bool
    @State private var targeted = false
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted {
                    HStack(spacing: 0) {
                        Circle().strokeBorder(palette.ink, lineWidth: 2).frame(width: 9, height: 9)
                        Capsule().fill(palette.ink).frame(height: 2)
                    }
                    .offset(y: -8).allowsHitTesting(false).transition(.opacity)
                }
            }
            .dropDestination(for: String.self) { ids, _ in perform(ids) } isTargeted: { targeted = $0 }
            .animation(Motion.quick, value: targeted)
            .sensoryFeedback(.selection, trigger: targeted) { _, now in now }
    }
}

extension View {
    /// 读看板（Mac 任务页、手机任务页同一处）：库变了重读；过了零点也重读一次——"今天做完"按读的那一刻分，库没变时日子换了也要换（同项目页）。
    func observingBoard(into board: Binding<TaskBoard?>, store: CueStore, onError: @escaping (any Error) -> Void) -> some View {
        modifier(BoardReading(board: board, store: store, onError: onError))
    }
}

private struct BoardReading: ViewModifier {
    @Binding var board: TaskBoard?
    let store: CueStore
    let onError: (any Error) -> Void
    @State private var day = 0

    func body(content: Content) -> some View {
        content
            .observing(store, id: day, into: $board, onError: onError) { try TaskBoard.read(from: $0) }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in day += 1 }
    }
}
