#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// 任务浮窗："任务 → 步骤 → 会话"。点任务或步骤（项目页、任务面板、⌘K、归档）就在当前页上弹出，不换页。
/// 没有步骤的任务一栏到底（与手机任务页同一个顺序）：完成圈与标题、所在项目，这件事此刻的样子，末尾一行添加步骤——不为一件事摆一个空着的左栏。
/// 有步骤时分两栏：左栏是这件事（标题、做到第几步、每个步骤一行：圈、名字、会话在动时一个状态点；选中的那一步名字就地可改），末尾添加步骤；
/// 右边是选中的那一步。只有没有步骤的任务（叶子）交给 Agent：还没开始时右边是它的正文（标题下面要交代的话）的输入框，
/// 开始就把标题连同正文交给会话（上一步的会话还开着就接着用它，否则开一个以它命名的新会话）；绑了会话后右边只是去会话的入口（随状态换的吉祥物、一句话、"打开会话"），话都在会话里说——
/// 这里看不到 Agent 最新的回复，不另给一个能发话的地方。完成它，它的会话也一起结束（还有没做完的事绑着它、或下一步会接着用它时不结束，规则在 `CueStore.endUnusedSessions`）。
struct TaskSheet: View {
    struct Request: Identifiable, Equatable {
        /// 顶层任务。
        let id: UUID
        /// 右边选中的步骤；nil 时取第一个没完成的步骤（没有步骤时就是任务自己）。换它不换浮窗（浮窗按 `id` 认）。
        var step: UUID?
    }

    let taskID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    @State private var data: SheetData?

    private static let size = CGSize(width: 860, height: 560)
    private static let single = CGSize(width: 600, height: 540)
    private static let sidebarWidth: CGFloat = 280

    var body: some View {
        let size = data?.steps.isEmpty == true ? Self.single : Self.size
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack(alignment: .topTrailing) {
            if let data {
                if data.steps.isEmpty { single(data) } else { split(data) }
                closeButton.padding(12)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(palette.desk)
        // 浮窗挂在页面之外：步骤的状态点、叶子去会话的入口读的"交给了哪个会话"在这里补上
        .modifier(WindowCardAgents(workspace: workspace))
        .observing(services.store, id: taskID, into: $data, onError: workspace.fail) { [taskID] in try SheetData.read(taskID, from: $0) }
        // 别处删掉、归档了它，或改回了灵感：浮窗收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
    }

    /// 没有步骤：一栏到底。
    private func single(_ data: SheetData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(data)
            if let project = data.project {
                HStack(spacing: 5) {
                    ProjectGlyph(project: project, size: 11)
                    Text(project.name).lineLimit(1)
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .padding(.leading, TaskMetrics.chipTarget + 6).padding(.top, 2)
            }
            LeafDetail(leaf: data.goal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(palette.hair).frame(height: 1).padding(.horizontal, -32)
            NewTaskField(project: data.goal.projectID, parent: data.goal.id).padding(.top, 10)
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 18)
    }

    private func split(_ data: SheetData) -> some View {
        let leaf = data.selected(workspace.openTask?.step)
        return HStack(spacing: 0) {
            sidebar(data, selected: leaf.id).frame(width: Self.sidebarWidth)
            LeafDetail(leaf: leaf)
                .id(leaf.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(36)
        }
    }

    /// 完成圈与标题（换成另一条任务时重建：标题的草稿只属于那一条）。
    private func heading(_ data: SheetData) -> some View {
        HStack(alignment: .top, spacing: 6) {
            GoalCheck(task: data.goal, subtasks: data.progress).padding(.top, 1)
            TaskHeading(task: data.goal).id(data.goal.id).padding(.trailing, 28)
        }
    }

    private func sidebar(_ data: SheetData, selected: UUID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                heading(data)
                if let progress = data.progress {
                    Text(TaskCopy.progress(progress)).font(Typography.meta).foregroundStyle(palette.ink3).monospacedDigit()
                        .padding(.leading, TaskMetrics.chipTarget + 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(data.steps) { StepRow(step: $0, selected: $0.id == selected) }
                    NewTaskField(project: data.goal.projectID, parent: data.goal.id)
                }
                // 步骤行的底向两边让出一截，落在栏的边距里
                .padding(.horizontal, RowMetrics.bleed)
                .padding(.top, 14)
            }
            .padding(.horizontal, 12).padding(.vertical, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(palette.sidebar, in: .rect)
    }

    private var closeButton: some View {
        Button("关闭", icon: .close) { close() }
            .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
            .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
            .buttonStyle(PressStyle())
            .help("关闭（Esc）")
    }
}

/// 左栏的一个步骤：圈（完成它，它的会话也结束）、名字（选中时就地可改）、会话在动或在等你时一个状态点；点行在右边看这一步。
/// 选中的是行的选中底，指针停着铺行的淡底（`RowStyle`）。
private struct StepRow: View {
    let step: Card
    let selected: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents
    @State private var check = TaskCheck()

    var body: some View {
        let done = check.done(step)
        // 开始在右边，这里只看会话那一格
        let next = workspace.next(for: step, in: agents, steps: nil)
        HStack(spacing: TaskMetrics.columnGap) {
            TaskCheckButton(
                task: step, agentBusy: next?.agentBusy ?? false, size: 14, target: CGSize(width: TaskMetrics.ringColumn, height: 14), check: $check,
                rowTap: select)
            if selected {
                TaskHeading(task: step, font: Typography.body).id(step.id)
            } else {
                Text(step.title).font(Typography.body).strikethrough(done, color: palette.ink3).foregroundStyle(done ? palette.ink3 : palette.ink).lineLimit(1)
            }
            Spacer(minLength: 4)
            if case .agent(let shown, let session) = next { PiStateDot(shown: shown, size: 6).relaySpot(session: session.sessionID) }
        }
        .animation(Motion.quick, value: done)
        .frame(minHeight: 32)
        .contentShape(.rect)
        .row(selected: selected, hovers: true)
        .environment(\.rowHoverPreset, DebugHooks.hovers(step.body))
        .onTapGesture(perform: select)
        .contextMenu { CardActions(card: step, leaf: true) }
    }

    private func select() { workspace.openTask?.step = step.id }
}

/// 右边：一个叶子任务此刻的样子。完成了是笑着的吉祥物；交给了会话是随状态换的吉祥物（在做时轻轻浮动）、一句话与"打开会话"；
/// 还没开始是挥手的吉祥物与正文的输入框（`BriefComposer`）。
private struct LeafDetail: View {
    let leaf: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents

    var body: some View {
        let item = agents.items[leaf.id]
        VStack(spacing: 0) {
            if leaf.status == .done {
                hero(.clean, floats: false, title: "完成了", note: nil)
                if let item { openSession(item.state.sessionID, primary: false) }
            } else if let item {
                let state = workspace.withLiveState(item.state)
                let shown = workspace.shown(state, delivery: item.delivery)
                let look = TaskAgentLook(shown, line: PiProgress.note(of: state, failure: shown.undelivered?.text(sync: workspace.services.syncStatus)))
                hero(look.mascot, floats: look.floats, title: look.title, note: look.note)
                openSession(state.sessionID, primary: true)
            } else {
                hero(.hello, floats: false, title: "交给 Agent 做这件事", note: nil)
                BriefComposer(leaf: leaf).id(leaf.id)
            }
        }
    }

    private func hero(_ mascot: Mascot, floats: Bool, title: String, note: String?) -> some View {
        VStack(spacing: 6) {
            MascotFigure(mascot: mascot, floats: floats).padding(.bottom, 14)
            Text(title).font(Typography.emptyTitle).foregroundStyle(palette.ink)
            Text(note ?? " ").font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(.bottom, 20)
    }

    private func openSession(_ sessionID: String, primary: Bool) -> some View {
        Button { workspace.show(.session(sessionID)) } label: {
            Text("打开会话").font(Typography.secondary.weight(.semibold))
                .foregroundStyle(primary ? palette.onFill : palette.ink)
                .padding(.horizontal, 28).frame(height: 40)
                .background(primary ? palette.signatureFill : palette.fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
    }
}

/// 吉祥物：透明底的图，脚下一圈淡阴影；Agent 在做时轻轻上下浮动（Core Animation，`LoopLayer.float`；减弱动态效果时不动）。
private struct MascotFigure: View {
    let mascot: Mascot
    let floats: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    private static let side: CGFloat = 120

    var body: some View {
        Group {
            if floats, !reduceMotion, let image = NSImage(named: mascot.rawValue)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                LoopLayer(kind: .float(image), color: .clear)
            } else {
                Image(mascot.rawValue).resizable().scaledToFit()
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(alignment: .bottom) {
            Ellipse().fill(RadialGradient(colors: [palette.shadow, .clear], center: .center, startRadius: 0, endRadius: 50))
                .frame(width: 90, height: 12).offset(y: 10)
        }
        .accessibilityHidden(true)
    }
}

/// 还没开始的叶子任务的输入框：一块玻璃，里面是它的正文（标题下面要交代给 Agent 的话，编辑器自动保存，⌘↩ 同"开始"）。
/// 左下"绑定会话"开新会话，或绑到本项目一个在跑的会话上（不发正文：话在会话里说）。打开时接过键盘；换一条、关浮窗都经
/// `CardEditing.leave` 写下没保存的字。
private struct BriefComposer: View {
    let leaf: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var editing: CardEditing?

    private static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let editing { editing.field(leaf, theme: .editor(palette, horizontalInset: 6)) } else { Color.clear }
            }
            .frame(height: 110)
            .overlay(alignment: .topLeading) {
                if editing?.text.isEmpty ?? true {
                    Text("要 Agent 做什么…").font(Typography.body).foregroundStyle(palette.ink3)
                        // 与编辑器第一行的字对齐（编辑器自己的内边距加上主题的 6）
                        .padding(.leading, 12).padding(.top, 8).allowsHitTesting(false)
                }
            }
            HStack(spacing: 10) {
                Menu { SessionBindItems(leaf: leaf) } label: {
                    Text("绑定会话").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer(minLength: 0)
                Text("⌘↩").font(Typography.meta).foregroundStyle(palette.ink3)
                Button { editing?.submit() } label: {
                    Text("开始").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.onFill)
                        .padding(.horizontal, 18).frame(height: 32)
                        .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .glass(in: .rect(cornerRadius: 22))
        .task {
            editing = CardEditing(leaf, part: .rest, workspace: workspace)
            await NextFrame.wait()
            editing?.handle.focus()
        }
        .onDisappear { editing?.leave() }
    }
}

/// 浮窗一次读出的东西：顶层任务、所在项目、它的步骤。
nonisolated private struct SheetData: Sendable, Equatable {
    var goal: Card
    var project: Project?
    var steps: [Card]
    /// 步骤完成了几个（`CueStore.subtaskProgress`）；没有步骤为 nil。
    var progress: TaskProgress?
    /// 已不是一条看得见的任务（删了、归档了、改回了灵感）。
    var gone: Bool { goal.deletedAt != nil || goal.archivedAt != nil || !goal.isTask }

    /// 右边看的叶子：点过的步骤，否则第一个没完成的步骤，再否则第一个步骤；没有步骤时是任务自己。
    func selected(_ step: UUID?) -> Card {
        steps.first { $0.id == step } ?? steps.first { $0.status != .done } ?? steps.first ?? goal
    }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> SheetData {
        guard let goal = try store.card(id) else { throw CueStoreError.notFound }
        let steps = try store.children(of: id).filter(\.isTask)
        return SheetData(
            goal: goal, project: try goal.projectID.flatMap { try store.project($0) }, steps: steps,
            progress: try store.subtaskProgress(of: [id])[id])
    }
}
#endif
