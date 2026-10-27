import CueStore
import SwiftUI

/// 四列并排（Mac、宽屏 iPad 与 iPhone 横屏的进展页）：每列（`BoardColumn`）的列头浮在顶上（`BoardColumnHeader`，写字玻璃），卡各自滚动、从列头后面过。
/// 列按可见宽、各列的份数分（`TaskBoard.Column.share`：推进中、等你宽，待办、已完成窄），四列总在眼前；列最窄 `minColumn`，放不下四列时（如 Mac 窄窗开着侧栏）
/// 整排横向滚动、最右一列露出一截（看得出能横划）：两侧页边是滚动区内容的边（`margin`），列滚到窗口边才裁，滚到头右边照样留页边。
/// 卡换列时从原处飞到新处（`boardFlight`），四列共用一个飞行的命名空间。
struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 两侧页边。
    let margin: CGFloat

    /// 一列最窄（三端同一个）：放得下圈、项目小图形与折两行后够读的标题（`BoardCardMetrics.title`）。
    /// iPad 竖屏、iPhone 横屏、Mac 900 宽收起侧栏的窗口都排得下四列；900 宽开着侧栏排不下，横滑（压窄到排得下时一行只剩三个字）。
    private static let minColumn: CGFloat = 160
    /// 列与列之间：列没有底，靠这段留白分开。
    private static let gap: CGFloat = 20

    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var flight

    var body: some View {
        // 按可见宽算一次各列宽与卡标题的行数，每列的卡都用这一份（几何读数只给子视图，不写回状态）
        GeometryReader { proxy in
            let unit = (proxy.size.width - margin * 2 - Self.gap * 3) / TaskBoard.Column.allCases.map(\.share).reduce(0, +)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(TaskBoard.Column.allCases) { item in
                        let width = max(Self.minColumn, unit * item.share)
                        BoardColumn(column: item, board: board, adding: $adding, newTaskProject: newTaskProject)
                            .frame(width: width)
                            .environment(\.boardTitle, BoardCardMetrics.title(item, cardWidth: width - 2 * BoardCardMetrics.inset, typeSize: typeSize))
                    }
                }
            }
            .safeAreaPadding(.horizontal, margin)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .environment(\.boardFlight, flight)
        }
    }
}

/// 看板的一列（`TaskBoard`；Mac 与宽屏 iPad 四列并排；手机转成一行，四行竖着排，`PhoneBoard`）：身后不铺底（`BoardLane`，拖进来时一层选中底），一件一张卡——
/// 待办、推进中、已完成是任务卡（`BoardTaskCard`）、没绑任务的会话卡（`BoardSessionCard`），等你是一件一张的卡（`BoardWaitCard`，拍板在前、待回复在后），都在懒加载栈里（列可能很长，只建看得见的）。
/// 推进中按档排（要你管 → 在跑 → 歇着，`Workspace.byAttention`），档与档之间多空一截；在跑的那一档只有前 `BoardLine.maxMoving` 张的线在动，
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
    #if os(iOS)
    /// 手机竖版看板的一行（`PhoneBoard`）：排成横着滑的一行（`BoardRowLane`）；否则是一列、列头浮在顶上（Mac、宽屏 iPad）。
    var row = false
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.boardMoved) private var moved
    @State private var showsEarlier = DebugHooks.preset.showsDone
    @State private var targeted = false
    /// 拖到已完成的那件与它这一下（同点完成圈，`taskCheck`）。
    @State private var finishing: TaskBoard.Item?
    @State private var check = TaskCheck()
    /// 点开的成果图（已完成列）。
    @State private var opened: PreviewOpening?

    var body: some View {
        fed
            .dropDestination(for: String.self) { ids, _ in
                drop(ids, before: nil)
            } isTargeted: { targeted = $0 && column != .todo && column != .waiting }
            .taskCheck(finishing?.task, subtasks: finishing?.steps, check: $check)
            .modifier(ShotPresenter(column: column, opened: $opened))
            // 有卡飞进来的那一列（行）排在别的列上面：往左、往上飞的卡不从别的列的卡下面钻过去（`boardFlight`）
            .zIndex(!moved.isEmpty && board.flights(column).contains(where: moved.contains) ? 1 : 0)
    }

    /// 推进中这一列的线要的"最近说过的话"（`SaidReading`）。
    @ViewBuilder private var fed: some View {
        if column == .advancing {
            let sessions = board.advancing.compactMap { workspace.sessionID($0, agents: agents) }.sorted()
            lane.modifier(SaidReading(sessions: sessions))
        } else {
            lane
        }
    }

    @ViewBuilder private var lane: some View {
        #if os(iOS)
        if row {
            BoardRowLane(column: column, count: board.count(column), targeted: targeted, rewind: adding && column == .todo ? board.todo.first?.id : nil) {
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

    /// 列头浮在卡上，卡从它后面滚过，不在它下沿裁掉（docs/ui.md 沉浸式的栏）：都是一块写字玻璃，Mac 上排进窗口最顶那一排（`boardTopRow`）。
    private var columnLane: some View {
        #if os(macOS)
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .boardTopRow(column: column, count: board.count(column))
            .background { BoardLane(targeted: targeted) }
        #else
        ScrollView { cards }
            .scrollBounceBehavior(.basedOnSize)
            .scrollClipDisabled()
            .safeAreaPadding(.top, BoardColumnHeader.height + BoardCardMetrics.inset)
            .overlay(alignment: .top) {
                BoardColumnHeader(column: column, count: board.count(column))
                    .padding(.horizontal, TaskMetrics.cardPadding)
                    .glass(in: .rect(cornerRadius: BoardCardMetrics.radius, style: .continuous))
                    .padding([.horizontal, .top], BoardCardMetrics.inset)
            }
            .background { BoardLane(targeted: targeted) }
        #endif
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
                card(item).draggable(item.id.uuidString).modifier(InsertBefore(id: item.id) { drop($0, before: item.id) })
            }
            if board.todo.isEmpty && !adding { empty("没有待办") }
        case .advancing:
            let groups = workspace.byAttention(board.advancing, agents: agents)
            ForEach(groups, id: \.tier) { group in
                // 档与档之间多空一截：栈里一格零高的空，前后各一个行距（横着的一行里一格就是一张卡宽，不空）
                if group.tier != groups.first?.tier, !isRow { Color.clear.frame(height: 0) }
                ForEach(Array(group.work.enumerated()), id: \.element.id) { index, work in
                    let moves = group.tier == .running && index < BoardLine.maxMoving
                    if let item = work.item {
                        card(item, moves: moves).draggable(item.id.uuidString)
                    } else if case .session(let session) = work.work {
                        BoardSessionCard(session: session, project: glyph(workspace.catalog?.project(work.project)), moves: moves)
                            .boardDim(project: work.project)
                            .boardFlight(work.id)
                    }
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            ForEach(board.held) { held in
                let card = BoardWaitCard(held: held, project: glyph(workspace.catalog?.project(held.project))).boardFlight(held.id)
                if let item = held.item { card.draggable(item.id.uuidString) } else { card }
            }
            if board.count(.waiting) == 0 { empty("没有等你的事") }
        case .done:
            ForEach(board.done) { card($0) }
            // 列头的数只数今天的：今天没有时先说没有，再接更早的，数与字对得上
            if board.done.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty { earlierToggle }
            if showsEarlier { ForEach(board.earlier) { card($0) } }
        }
    }

    private func card(_ item: TaskBoard.Item, moves: Bool = false) -> some View {
        BoardTaskCard(item: item, column: column, project: glyph(item.project), moves: moves) { opened = $0 }
            .boardDim(project: item.task.projectID)
            .boardFlight(item.flight)
    }

    /// 卡上的项目小图形：只看一个项目时不画（范围已经说了）。
    private func glyph(_ project: Project?) -> Project? { workspace.scopedProject == nil ? project : nil }

    @ViewBuilder private var newTask: some View {
        #if os(macOS)
        NewTaskField(project: newTaskProject, choosesProject: true, autofocus: true) { adding = false }
            .padding(.horizontal, TaskMetrics.cardPadding)
            .paper(radius: TaskMetrics.cardRadius)
        #else
        NewTaskLine(project: newTaskProject, projects: workspace.catalog?.projects) { adding = false }
            .padding(.horizontal, 6)
            .paper(radius: TaskMetrics.cardRadius)
        #endif
    }

    private func empty(_ text: LocalizedStringResource) -> some View {
        Text(text).font(Typography.secondary).foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, minHeight: isRow ? nil : 64, maxHeight: isRow ? .infinity : nil)
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
        // 手机一行里它占一格：与旁边的空格一样高、字在中间
        .frame(maxHeight: isRow ? .infinity : nil)
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
        if column == .done { content.previewPresenter($opened, reply: .cue) } else { content }
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
            .animation(HandOff.quick, value: targeted)
            .sensoryFeedback(.selection, trigger: targeted) { _, now in now }
    }
}

extension View {
    /// 读看板（三端进展页同一处）：库变了重读；过了零点也重读一次——"今天做完"按读的那一刻分，库没变时日子换了也要换（同项目页）。
    /// 看板怎么动只在这里定：第一份是页面打开的样子、不动；之后每一份都在一个动画事务里换上（`Motion.move`，减弱动态效果时直接到终态），
    /// 卡的出现、消失、列内让位与换列（`boardFlight`）都跟着这一份走，各列各行不再各挂动画。
    func observingBoard(into board: Binding<TaskBoard?>, store: CueStore, onError: @escaping (any Error) -> Void) -> some View {
        modifier(BoardReading(board: board, store: store, onError: onError))
    }
}

private struct BoardReading: ViewModifier {
    @Binding var board: TaskBoard?
    let store: CueStore
    let onError: (any Error) -> Void
    @State private var day = 0
    @State private var moved: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.boardMoved, moved)
            .observing(store, id: day, into: Binding { board } set: { read in
                guard let board, let read else { return board = read }
                withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) {
                    moved = read.moved(from: board)
                    self.board = read
                }
            }, onError: onError) { try TaskBoard.read(from: $0) }
            .onDayChange { day += 1 }
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
