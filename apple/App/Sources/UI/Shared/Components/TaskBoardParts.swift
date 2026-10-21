import CueStore
import SwiftUI

/// 四列并排（Mac 任务页、宽屏 iPad）：列头（`BoardColumnHeader`）加一列卡（`BoardColumn`），各自滚动。
/// 列按可见宽四等分，窄到一列放不下 `minColumn` 时整排横向滚动。
struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?

    #if os(macOS)
    private static let minColumn: CGFloat = 230
    #else
    /// 一行要放下 44pt 的圈、两行标题与行尾的时间和状态标：iPad 竖屏放三列多一点，横滑看第四列。
    private static let minColumn: CGFloat = 260
    #endif
    private static let gap: CGFloat = 14

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(TaskBoard.Column.allCases) { column in
                    VStack(alignment: .leading, spacing: 10) {
                        BoardColumnHeader(column: column, count: board.count(column)).padding(.horizontal, 8)
                        BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject)
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in max(Self.minColumn, (width - Self.gap * 3) / 4) }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// 看板的一列（`TaskBoard`；Mac 与宽屏 iPad 四列并排，手机一屏一列）：待办、推进中、做完各是一张纸（`BoardPaper`），等你每件一张卡（`BoardWaitCard`），
/// 都在懒加载栈里（列可能很长，只建看得见的）。推进中按要不要你管排（`Workspace.byAttention`）。
/// 拖放：行拖到推进中是开始（同"开始"：Mac 交给 Agent，手机浮起发给 Agent 的输入框）、拖到做完是做完（同点完成圈，还有没完成的步骤、
/// Agent 还在做时先问一句，`TaskCheck`）；待办里拖到一行前面是排序（`TaskBoard.move`），拖进来不改状态。别的拖法不接。
/// 做完列末尾是"更早做完的 N"：原地展开（它们没进归档，跳去归档页看到的是别的），展开后旁边是"全部归档"。
struct BoardColumn: View {
    let column: TaskBoard.Column
    /// 按项目范围筛过的看板。
    let board: TaskBoard
    /// 待办顶上浮出添加任务那一行（"+ 新任务"）；新任务落在 `newTaskProject`。
    @Binding var adding: Bool
    let newTaskProject: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif
    @State private var showsEarlier = DebugHooks.preset.showsDone
    @State private var targeted = false
    /// 拖到做完的那件与它这一下（同点完成圈，`taskCheck`）。
    @State private var finishing: TaskBoard.Item?
    @State private var check = TaskCheck()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.gap) { content }
                .padding(.horizontal, Self.inset).padding(.bottom, 24)
                .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: ids)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            RoundedRectangle(cornerRadius: TaskMetrics.cardRadius + Self.inset, style: .continuous)
                .fill(targeted ? palette.selection : .clear)
                .animation(Motion.quick, value: targeted)
        }
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, before: nil)
        } isTargeted: { targeted = $0 && column != .todo && column != .waiting }
        .taskCheck(finishing?.task, subtasks: finishing?.steps, check: $check)
    }

    private static let gap: CGFloat = 8
    /// 纸离列边的空：拖进来时铺的淡底比纸宽出这一截。
    private static let inset: CGFloat = 4

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
            BoardPaper(rows: board.todo, project: \.task.projectID) { item in
                line(item).draggable(item.id.uuidString).modifier(InsertBefore(id: item.id) { drop($0, before: item.id) })
            }
            if board.todo.isEmpty && !adding { empty("没有待办") }
        case .advancing:
            BoardPaper(rows: workspace.byAttention(board.advancing, agents: agents), project: \.project) { work in
                if let item = work.item {
                    line(item).draggable(item.id.uuidString)
                } else if case .session(let session) = work.work {
                    BoardSessionRow(session: session)
                }
            }
            if board.advancing.isEmpty { empty("拖一件待办到这里开始") }
        case .waiting:
            ForEach(BoardSection.of(board.waiting, by: \.project)) { section in
                if workspace.scopedProject == nil { BoardProjectHeading(id: section.id, first: section.first).padding(.leading, BoardInset.ring + TaskMetrics.cardPadding - Self.inset) }
                ForEach(section.rows) { wait in
                    if let item = wait.item {
                        BoardWaitCard(wait: wait).draggable(item.id.uuidString)
                    } else {
                        BoardWaitCard(wait: wait)
                    }
                }
            }
            if board.waiting.isEmpty { empty("没有要你拍板的事") }
        case .done:
            BoardPaper(rows: board.done, project: \.task.projectID, content: line)
            if board.done.isEmpty && board.earlier.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty { earlierToggle }
            if showsEarlier { BoardPaper(rows: board.earlier, project: \.task.projectID, content: line) }
        }
    }

    private func line(_ item: TaskBoard.Item) -> TaskLine { TaskLine(task: item.task, subtasks: item.steps, lead: item.leaf) }

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
            .buttonStyle(.plain)
            .accessibilityValue(showsEarlier ? "已展开" : "已折叠")
            Spacer(minLength: 0)
            if showsEarlier {
                // 做完的一键收走：归档后不占列表，照样搜得到
                Button("全部归档") { workspace.attempt { try await workspace.archiveCompletedTasks() } }
                    .buttonStyle(.plain).frame(minHeight: TaskMetrics.chipTarget)
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

    private func start(_ task: Card) {
        #if os(macOS)
        workspace.handOff(task)
        #else
        navigation.handToAgent(task)
        #endif
    }

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

/// 列头：列的状态图形、列名、数（做完写"今天"）。图形只用现成的：待办空圈、推进中半圈（`TaskRingView`）、等你赭黄问号（`PiStateGlyph`）、做完对勾。
struct BoardColumnHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BoardColumnGlyph(column: column)
            Text(column.title).font(Self.font).foregroundStyle(palette.ink)
            if column == .done { Text("今天").font(Self.countFont).foregroundStyle(palette.ink3) }
            Text("\(count)").font(Self.countFont).monospacedDigit().foregroundStyle(palette.ink3).counting(count)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private static let font = Typography.secondary.weight(.semibold)
    private static let countFont = Typography.meta
    #else
    private static let font = Font.headline
    private static let countFont = Font.subheadline
    #endif
}

/// 一列的状态图形（列头、手机的分段胶囊）。
struct BoardColumnGlyph: View {
    let column: TaskBoard.Column
    var size: CGFloat = 13

    var body: some View {
        switch column {
        case .todo: TaskRingView(status: .todo, done: false, size: size)
        case .advancing: TaskRingView(status: .inProgress, done: false, size: size)
        case .waiting: PiStateGlyph(status: .asking).font(.system(size: size))
        case .done: TaskRingView(status: .done, done: true, size: size)
        }
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
