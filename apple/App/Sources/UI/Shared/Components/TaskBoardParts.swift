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
                if workspace.projectScope == nil { BoardProjectHeading(id: section.id, first: section.first).padding(.leading, BoardInset.ring + TaskMetrics.cardPadding - Self.inset) }
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

/// 待办、推进中、做完一列的那张纸：行是全 App 那一种任务行（`TaskLine`，上级收成一行、状态看此刻干活的叶子），没绑任务的活会话是会话列表的那一行。
/// 看的是全部项目时按项目分段（`BoardSection`），段头写一次项目（`BoardProjectHeading`）；只有一件的项目也不另起一张纸：一列一张，读着是一份清单。
private struct BoardPaper<Row: Identifiable, Content: View>: View {
    let rows: [Row]
    let project: (Row) -> UUID?
    @ViewBuilder let content: (Row) -> Content
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if !rows.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(BoardSection.of(rows, by: project)) { section in
                    if workspace.projectScope == nil { BoardProjectHeading(id: section.id, first: section.first).padding(.leading, BoardInset.ring) }
                    ForEach(section.rows) { content($0) }
                }
            }
            .padding(BoardInset.paper)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: TaskMetrics.cardRadius)
        }
    }
}

/// 看板一列里按项目分的一段，段的先后是它第一次出现的先后；不属于哪个项目的（Cue 的一般提问）在最前，不写段头。
/// 只看一个项目时不分段写头（范围已经说了）。
struct BoardSection<Row: Identifiable>: Identifiable {
    var id: UUID?
    var rows: [Row]
    var first = false

    static func of(_ rows: [Row], by project: (Row) -> UUID?) -> [Self] {
        var sections: [Self] = []
        for row in rows {
            let key = project(row)
            if let index = sections.firstIndex(where: { $0.id == key }) { sections[index].rows.append(row) } else { sections.append(Self(id: key, rows: [row])) }
        }
        if let index = sections.firstIndex(where: { $0.id == nil }), index > 0 { sections.insert(sections.remove(at: index), at: 0) }
        if !sections.isEmpty { sections[0].first = true }
        return sections
    }
}

/// 段头：项目小图标与名字，淡墨小字；第一段贴着上沿，其后的与上一段隔一点。
struct BoardProjectHeading: View {
    let id: UUID?
    let first: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if let project = workspace.catalog?.project(id) {
            HStack(spacing: 5) {
                ProjectGlyph(project: project, size: Self.glyph)
                Text(project.name).lineLimit(1)
            }
            .font(TaskMetrics.caption.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.top, first ? 6 : 14).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
        }
    }

    #if os(macOS)
    private static let glyph: CGFloat = 10
    #else
    private static let glyph: CGFloat = 12
    #endif
}

/// 纸与卡里的对齐：手机的行没有左右内边距（圈那一列自带点按宽），段头、会话行与卡里的任务行按 `ring` 让到圈的位置。
enum BoardInset {
    #if os(macOS)
    static let paper = EdgeInsets(top: 4, leading: 12, bottom: 6, trailing: 12)
    static let ring: CGFloat = 0
    #else
    /// 右边留一点，行尾的状态标不贴边。
    static let paper = EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 10)
    static let ring: CGFloat = (TaskMetrics.ringColumn - TaskMetrics.ring) / 2
    #endif
}

extension Workspace {
    /// 推进中的先后：行上写出状态词的（要你管：等你、出错、被打断、有新回复…，`PiShown.speaksOnTask`）在前，其次在跑的，再次歇着的；同一档保持原来的先后。
    func byAttention(_ work: [TaskBoard.Work], agents: AgentLinks) -> [TaskBoard.Work] {
        func rank(_ work: TaskBoard.Work) -> Int {
            let shown: PiShown? = switch work.work {
            case .task:
                work.item.flatMap { item -> PiShown? in
                    guard case .agent(let shown, _)? = next(for: item.task, lead: item.leaf, in: agents, steps: item.steps) else { return nil }
                    return shown
                }
            case .session(let session): self.shown(session, delivery: services.liveSessions.deliveries[session.sessionID])
            }
            guard let shown else { return 2 }
            return shown.speaksOnTask ? 0 : shown.isRunning ? 1 : 2
        }
        return work.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// 等你列的一张卡：上面是它落在的任务（同一种任务行 `TaskLine`），没落在任务上的会话写会话名与"没绑任务"；下面就地处理——
/// Cue 的提问是要你定什么与它的选项（`CueChoices`，与 Cue 页"等你"卡同一套，答的方法同 `AppServices.answerCueQuestion`）；
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
            TaskLine(task: item.task, subtasks: item.steps, lead: item.leaf).padding(.leading, -BoardInset.ring)
        } else if case .session(let session, _) = wait.wait {
            BoardSessionHeader(session: session)
        }
    }

    /// 要你定什么那一句；Cue 问的前面写它的名字。不再画问号：列名与任务行尾的状态标已经说了在等你。
    private func question(_ text: String, by asker: String?) -> some View {
        Text([asker, CueQuestionLine.keepingTail(text)].compactMap(\.self).joined(separator: " "))
            .font(Typography.secondary.weight(.medium))
            .foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
    }

    private func answer(_ message: CueMessage, _ choice: String) {
        ending = true
        workspace.attempt {
            defer { ending = false }
            try await workspace.services.answerCueQuestion(message.id, choice)
        }
    }

}

/// 推进中那一列里一个没绑没做完的任务的活会话（终端里开的、"新会话"、只有已完成的事绑着的）：就是会话列表的那一行（`PiSessionRow`，菜单栏面板、Cue 页头面板同一种），
/// 在纸里它所在项目那一段（段头已经写了项目，行里不再写），点了打开会话。
private struct BoardSessionRow: View {
    let session: PiSessionState
    @Environment(AppServices.self) private var services

    var body: some View {
        let live = services.liveSessions
        BoardSessionLink(session: session) {
            PiSessionRow(
                session: session, project: nil, delivery: live.deliveries[session.sessionID],
                rename: live.renames[session.sessionID], undelivered: live.undelivered[session.sessionID] ?? 0
            ).equatable()
                .padding(.leading, BoardInset.ring).padding(.vertical, 8)
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

/// 看板上点了打开会话的一块（推进中的会话行、等你卡的抬头）。
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

#if os(macOS)
/// 项目范围（`Workspace.projectScope`，任务页与会话页共用一份）在 Mac 任务页顶上的入口：全部项目或一个项目，列全部项目。
/// 手机与 iPad 的入口在顶栏中间（`ProjectScope`）。选中的项目进了回收站就当作全部项目。
struct ProjectScopeMenu: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var workspace = workspace
        let current = workspace.catalog?.project(workspace.projectScope)
        Menu {
            Picker("项目范围", selection: $workspace.projectScope) {
                Label("全部项目", icon: .all).tag(UUID?.none)
                ForEach(workspace.catalog?.projects ?? []) { project in
                    Label { Text(project.name) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let current { ProjectGlyph(project: current, size: 13) } else { Image(.all) }
                Text(current?.name ?? "全部项目").lineLimit(1)
            }
            .font(Typography.toolbarLabel).foregroundStyle(palette.ink2)
            .padding(.horizontal, 12).frame(height: Spacing.toolbarControl)
            .glass(in: .capsule, interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(current.map { "项目范围：\($0.name)" } ?? "项目范围：全部项目")
    }
}
#endif

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
