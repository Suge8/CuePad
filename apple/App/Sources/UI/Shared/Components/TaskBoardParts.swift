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
    /// iPad 竖屏（侧栏收着）也四列并排放得下。
    private static let minColumn: CGFloat = 180
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

/// 看板的一列（`TaskBoard`；Mac 与宽屏 iPad 四列并排，手机一屏一列）：卡片在懒加载栈里（列可能很长，只建看得见的）。
/// 拖放：卡片拖到在管是开始（同"开始"：Mac 交给 Agent，手机浮起发给 Agent 的输入框）、拖到做完是做完（同点完成圈，还有没完成的步骤、
/// Agent 还在做时先问一句，`TaskCheck`）；待办里拖到一张卡前面是排序（`TaskBoard.move`），拖进来不改状态。别的拖法不接。
/// 做完列末尾是"更早做完的 N"：原地展开（它们没进归档，跳去归档页看到的是别的），展开后旁边是"全部归档"。
struct BoardColumn: View {
    let column: TaskBoard.Column
    /// 筛过项目的看板。
    let board: TaskBoard
    /// 待办顶上浮出添加任务那一行（"+ 新任务"）；新任务落在 `newTaskProject`。
    @Binding var adding: Bool
    let newTaskProject: UUID?
    @Environment(Workspace.self) private var workspace
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
            LazyVStack(alignment: .leading, spacing: Self.gap) { cards }
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
    /// 卡离列边的空：拖进来时铺的淡底比卡宽出这一截。
    private static let inset: CGFloat = 4

    private var ids: [String] {
        switch column {
        case .todo: board.todo.map(\.id.uuidString)
        case .managing: board.managing.map(\.id)
        case .waiting: board.waiting.map(\.id)
        case .done: board.done.map(\.id.uuidString) + (showsEarlier ? board.earlier.map(\.id.uuidString) : [])
        }
    }

    @ViewBuilder private var cards: some View {
        switch column {
        case .todo:
            if adding {
                newTask.transition(Motion.item)
            }
            ForEach(board.todo) { item in
                BoardTaskCard(item: item).draggable(item.id.uuidString).modifier(InsertBefore(id: item.id) { drop($0, before: item.id) })
            }
            if board.todo.isEmpty && !adding { empty("没有待办") }
        case .managing:
            ForEach(board.managing) { work in
                if let item = work.item {
                    BoardTaskCard(item: item).draggable(item.id.uuidString)
                } else if case .session(let session) = work.work {
                    BoardSessionCard(session: session)
                }
            }
            if board.managing.isEmpty { empty("拖一件待办到这里开始") }
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
            ForEach(board.done) { BoardTaskCard(item: $0) }
            if board.done.isEmpty && board.earlier.isEmpty { empty("今天还没做完的") }
            if !board.earlier.isEmpty { earlierToggle }
            if showsEarlier { ForEach(board.earlier) { BoardTaskCard(item: $0) } }
        }
    }

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
        case .managing:
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
        let busy = item.leaf.flatMap { workspace.next(for: $0, in: workspace.agentLinks, steps: nil) }?.agentBusy ?? false
        finishing = item
        check = TaskCheck()
        workspace.tap($check, task: item.task, subtasks: item.steps, agentBusy: busy)
    }
}

extension TaskBoard {
    /// 看板上的这件任务（在哪一列都算）。
    func item(_ id: UUID) -> Item? {
        todo.first { $0.id == id } ?? managing.lazy.compactMap(\.item).first { $0.id == id } ?? waiting.lazy.compactMap(\.item).first { $0.id == id }
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

/// 列头：列的状态图形、列名、数（做完写"今天"）。图形只用现成的：待办空圈、在管半圈（`TaskRingView`）、等你赭黄问号（`PiStateGlyph`）、做完对勾。
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
        case .managing: TaskRingView(status: .inProgress, done: false, size: size)
        case .waiting: PiStateGlyph(status: .asking).font(.system(size: size))
        case .done: TaskRingView(status: .done, done: true, size: size)
        }
    }
}

/// 看板上的一张任务卡（纸）：完成圈（`TaskCheckButton`）、标题，下面一行项目小图标与名字、步骤 n/m，
/// 交给了会话的再一行会话此刻在做什么——"下一步"那一格（`TaskNextMark`，状态样子只经 `PiShown`，在跑是会动的线）、会话名，与它此刻的进展（`PiProgress`）；
/// 还没交出去的叶子在标题行尾是"开始"（Mac 指针停在卡上才露出）。点卡从那一下长出任务气泡（`Workspace.openTask`），Mac 右键是 `CardActions`。
struct BoardTaskCard: View {
    let item: TaskBoard.Item
    @State private var check = TaskCheck()
    @State private var hovering = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette

    var body: some View {
        let next = item.task.status == .done ? nil : item.leaf.flatMap { workspace.next(for: $0, in: agents, steps: nil) }
        let done = check.done(item.task)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Self.titleGap) {
                ring(agentBusy: next?.agentBusy ?? false)
                // 做完列里的不划线（列名已经说了），只淡一档；刚点了圈、还在停留的那一下才划线
                Text(item.task.title.textGlyphs).font(TaskMetrics.lineFont)
                    .strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(done ? palette.ink2 : palette.ink)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                #if os(macOS)
                // 还没交出去的"开始"跟在标题这一行尾上：Mac 上悬停才露出，占的是这一行本来就有的高，卡不因悬停变高
                if let next, case .start = next { TaskNextMark(next: next) }
                #endif
            }
            meta(start: Self.startsInMeta ? next : nil).padding(.leading, Self.indent)
            if let next, case .agent = next { BoardNextLine(next: next).padding(.leading, Self.indent) }
        }
        .padding(TaskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: TaskMetrics.cardRadius)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .environment(\.rowHovered, hovering)
        #if os(macOS)
        .onHover { hovering = $0 }
        .contextMenu { CardActions(card: item.task, leaf: item.steps == nil) }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "打开", open)
        .animation(Motion.quick, value: done)
    }

    #if os(macOS)
    private static let ringTarget = CGSize(width: TaskMetrics.ring, height: 15)
    private static let titleGap: CGFloat = 8
    #else
    private static let ringTarget = CGSize(width: 32, height: 32)
    private static let titleGap: CGFloat = 4
    #endif
    /// 第二行起与标题对齐。
    private static let indent = ringTarget.width + titleGap

    private func ring(agentBusy: Bool) -> some View {
        #if os(macOS)
        TaskCheckButton(task: item.task, subtasks: item.steps, agentBusy: agentBusy, size: TaskMetrics.ring, target: Self.ringTarget, check: $check, rowTap: open)
        #else
        TaskCheckButton(task: item.task, subtasks: item.steps, agentBusy: agentBusy, size: TaskMetrics.ring, target: Self.ringTarget, check: $check)
        #endif
    }

    /// 手机上"开始"一直露着，放在项目那一行尾上，不占标题的宽（窄列里标题会被挤成三行）。
    #if os(macOS)
    private static let startsInMeta = false
    #else
    private static let startsInMeta = true
    #endif

    @ViewBuilder private func meta(start next: TaskNext?) -> some View {
        let start: TaskNext? = if let next, case .start = next { next } else { nil }
        if item.project != nil || item.steps != nil || start != nil {
            HStack(spacing: 10) {
                if let project = item.project {
                    HStack(spacing: 4) {
                        ProjectGlyph(project: project, size: 11)
                        Text(project.name).lineLimit(1)
                    }
                }
                if let steps = item.steps { Text(TaskCopy.progress(steps)).monospacedDigit() }
                // 写成"▶ 开始"、不占 44pt 高的点按格：卡已经是可点的大块，这一格只是说明能开始
                if let start { TaskNextMark(next: start, spelled: true).fixedSize() }
            }
            .font(TaskMetrics.caption).foregroundStyle(palette.ink3)
        }
    }

    private func open() { workspace.openTask(item.task) }
}

/// 卡上会话那一行：状态标与状态词（`TaskNextMark`，点了打开会话），会话名；下面一行它此刻的进展（`PiProgress`）。
private struct BoardNextLine: View {
    let next: TaskNext
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // 状态词不让：窄列里先截会话名
                TaskNextMark(next: next, spelled: true).fixedSize()
                if case .agent(_, let session) = next {
                    Text(session.title).font(TaskMetrics.caption.monospaced()).foregroundStyle(palette.ink2).lineLimit(1)
                }
            }
            if case .agent(_, let session) = next, let line = PiProgress.line(of: session) {
                Text(line).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1)
            }
        }
    }
}

/// 等你列的一张卡：上面是它落在的任务（点了打开），没落在任务上的会话写会话名与"没绑任务"；下面就地处理——
/// Cue 的提问是要你定什么与它的选项（`CueChoices`，与 Cue 页"等你"卡同一套，答的方法同 `Workspace.answerCueQuestion`）；
/// 会话在问的是问题与回答框（`BoardReply`，与会话页回复同一个发送方法）。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 正在答的那条（写成后它从等你里消失，写不成就清掉）。
    @State private var ending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch wait.wait {
            case .message(let message, _):
                question(message.headline ?? "", by: workspace.cue.name)
                CueChoices(options: message.choices ?? [], disabled: ending, stacks: true) { answer(message, $0) }
            case .session(let session, _):
                // 在问的是整段问题连同选项（回答框里写选项原文或序号）；Cue 留给你回的是它最后那句的首句
                question(session.question?.displayText ?? PiProgress.line(of: session) ?? workspace.shown(session, delivery: nil).label, by: nil)
                BoardReply(session: session)
            }
        }
        .padding(TaskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: TaskMetrics.cardRadius)
    }

    @ViewBuilder private var header: some View {
        if let item = wait.item {
            Button { open(item.task) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TaskRingView(status: item.task.status, done: false, size: TaskMetrics.ring)
                        Text(item.task.title.textGlyphs).font(TaskMetrics.lineFont).foregroundStyle(palette.ink).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let project = item.project {
                        HStack(spacing: 4) {
                            ProjectGlyph(project: project, size: 11)
                            Text(project.name).lineLimit(1)
                        }
                        .font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                        .padding(.leading, TaskMetrics.ring + 8)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(.card))
            .accessibilityHint("打开任务")
        } else if case .session(let session, _) = wait.wait {
            BoardSessionHeader(session: session)
        }
    }

    /// 要你定什么：赭黄问号（`PiStateGlyph`）与那一句；Cue 问的前面写它的名字。
    private func question(_ text: String, by asker: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            PiStateGlyph(status: .asking)
            Text([asker, CueQuestionLine.keepingTail(text)].compactMap(\.self).joined(separator: " "))
                .foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typography.secondary.weight(.medium))
        .accessibilityElement(children: .combine)
    }

    private func answer(_ message: CueMessage, _ choice: String) {
        ending = true
        workspace.attempt {
            defer { ending = false }
            try await workspace.answerCueQuestion(message, choice)
        }
    }

    private func open(_ task: Card) { workspace.openTask(task) }
}

/// 在管列里一个没绑没做完的任务的活会话（终端里开的、"新会话"、只有已完成的事绑着的）：就是会话列表的那一行（`PiSessionRow`，菜单栏面板、Cue 页头面板同一种）铺在纸上，点了打开会话。
private struct BoardSessionCard: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let live = services.liveSessions
        BoardSessionLink(session: session) {
            PiSessionRow(
                session: session, project: workspace.catalog?.project(session.projectID), delivery: live.deliveries[session.sessionID],
                rename: live.renames[session.sessionID], undelivered: live.undelivered[session.sessionID] ?? 0
            ).equatable()
                .padding(TaskMetrics.cardPadding)
                .paper(radius: TaskMetrics.cardRadius)
        }
    }
}

/// 等你卡上没绑任务的会话的抬头：会话名与"会话 · 没绑任务"，点了打开会话。
private struct BoardSessionHeader: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        BoardSessionLink(session: session) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(.session).foregroundStyle(palette.ink2)
                    Text(session.title).font(TaskMetrics.lineFont.monospaced()).foregroundStyle(palette.ink).lineLimit(1)
                }
                Text(Dotted("会话", "没绑任务")).font(TaskMetrics.caption).foregroundStyle(palette.ink3)
            }
        }
    }
}

/// 看板上点了打开会话的一块（在管的会话卡、等你卡的抬头）。
private struct BoardSessionLink<Label: View>: View {
    let session: PiSessionState
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        Button(action: open) {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint("打开会话")
    }

    private func open() {
        #if os(macOS)
        workspace.show(.session(session.sessionID))
        #else
        navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
        #endif
    }
}

/// 等你卡上回答会话的一行：草稿就是会话页回复框那一份（`AppSettings.replyDraft`，两处写的是同一句），发出同会话页的作答
/// （`Workspace.speak`：会话在等 CuePad 答得了的提问时这句就是答案，选项写原文或序号）；只发文字，草稿里的卡片与图片留给会话页。
/// 同步到不了 Mac 时不能发（同回复框）。
struct BoardReply: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }
    private var canSend: Bool { services.reachesPiHost && !box.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("回答 \(session.title)", text: box.text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Typography.secondary).lineLimit(1...4)
                .padding(.vertical, 7)
                .onSubmit(send)
            Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        }
        .padding(.leading, 12).padding(.trailing, 3).padding(.vertical, 3)
        .background(palette.fill, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func send() {
        guard canSend else { return }
        _ = workspace.speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) { draft in
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// 按项目筛的一排胶囊（Mac 任务页、宽屏 iPad）："全部"与看板上有事的项目（项目目录的顺序）；选中的是靛青浅底（`selection`）。
struct BoardProjectChips: View {
    let projects: [Project]
    @Binding var selected: UUID?
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(nil) { Text("全部") }
                ForEach(projects) { project in
                    chip(project.id) {
                        HStack(spacing: 5) {
                            ProjectGlyph(project: project, size: 11)
                            Text(project.name).lineLimit(1)
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func chip(_ id: UUID?, @ViewBuilder label: () -> some View) -> some View {
        let on = selected == id
        return Button { selected = id } label: {
            label()
                .font(Typography.secondary.weight(on ? .semibold : .regular)).foregroundStyle(on ? palette.ink : palette.ink2)
                .padding(.horizontal, 12).frame(minHeight: Self.height)
                .background(on ? palette.selection : palette.fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    #if os(macOS)
    private static let height: CGFloat = 28
    #else
    private static let height: CGFloat = 36
    #endif
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

extension TaskBoard {
    /// 看板上有事的项目（筛选胶囊列它们），按项目目录的顺序。
    func projects(in catalog: ProjectCatalog?) -> [Project] {
        let used = Set((todo + done + earlier).map(\.task.projectID) + managing.map(\.project) + waiting.compactMap(\.project))
        return catalog?.projects.filter { used.contains($0.id) } ?? []
    }
}
