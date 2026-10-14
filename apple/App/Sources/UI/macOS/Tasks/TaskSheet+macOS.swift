#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// 任务浮窗："任务 → 步骤 → 会话"。点任务、步骤或它的草稿（项目页、任务面板、⌘K、归档）就在当前页上弹出，不换页。
/// 左栏是这件事：标题、做到第几步、每个步骤一行（圈、名字、会话在动时一个状态点；选中的那一步名字就地可改），末尾添加步骤；
/// 右边是选中的那一步——没有步骤的任务就是它自己。只有没有步骤的任务（叶子）交给 Agent：还没开始时右边是"要 Agent 做什么"的输入框，
/// 开始就交给会话（上一步的会话还开着就接着用它，否则开一个以它命名的新会话）；绑了会话后右边只是去会话的入口（随状态换的吉祥物、一句话、"打开会话"），话都在会话里说——
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
    private static let sidebarWidth: CGFloat = 280

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack(alignment: .topTrailing) {
            if let data {
                let leaf = data.selected(workspace.openTask?.step)
                HStack(spacing: 0) {
                    sidebar(data, selected: leaf.id).frame(width: Self.sidebarWidth)
                    LeafDetail(leaf: leaf, draft: data.drafts[leaf.id])
                        .id(leaf.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(36)
                }
                closeButton.padding(12)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(palette.desk)
        // 浮窗挂在页面之外：步骤的状态点、叶子去会话的入口读的"交给了哪个会话"在这里补上
        .modifier(WindowCardAgents(workspace: workspace))
        .observing(services.store, id: taskID, into: $data, onError: workspace.fail) { [taskID] in try SheetData.read(taskID, from: $0) }
        // 别处删掉、归档了它，或改回了灵感：浮窗收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
    }

    private func sidebar(_ data: SheetData, selected: UUID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    TaskRingButton(task: data.goal, prompts: 0, subtasks: data.progress, size: 18).padding(.top, 1)
                    // 换成另一条任务时重建：标题的草稿只属于那一条
                    TaskHeading(task: data.goal).id(data.goal.id)
                }
                if let progress = data.progress {
                    Text("\(progress.done)/\(progress.total) 步").font(Typography.meta).foregroundStyle(palette.ink3).monospacedDigit()
                        .padding(.leading, TaskMetrics.chipTarget + 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(data.steps) { StepRow(step: $0, selected: $0.id == selected) }
                    NewTaskField(project: data.goal.projectID, parent: data.goal.id)
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 12).padding(.vertical, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(palette.sidebar)
    }

    private var closeButton: some View {
        Button("关闭", systemImage: "xmark") { close() }
            .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
            .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
            .buttonStyle(PressStyle())
            .help("关闭（Esc）")
    }
}

/// 左栏的一个步骤：圈（完成它，它的会话也结束）、名字（选中时就地可改）、会话在动或在等你时一个状态点；点行在右边看这一步。
private struct StepRow: View {
    let step: Card
    let selected: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents
    @State private var hovering = false

    var body: some View {
        let done = step.status == .done
        let shown = done ? nil : agents.items[step.id].map { workspace.shown(workspace.withLiveState($0.state), delivery: $0.delivery) }
        HStack(spacing: TaskRow.columnGap) {
            TaskCompletionRing(task: step, agentBusy: shown.flatMap { TaskNext(shown: $0, sessionID: "", hasDraft: false) }?.agentBusy ?? false, size: 14)
            if selected {
                TaskHeading(task: step, font: Typography.body).id(step.id)
            } else {
                Text(step.title).font(Typography.body).strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shown, TaskNext.wantsLook(shown) { PiStateDot(shown: shown, size: 6) }
        }
        .padding(.horizontal, TaskRow.inset).frame(minHeight: 32)
        .background(selected ? palette.paperLit.opacity(0.8) : hovering ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { workspace.openTask?.step = step.id }
        .contextMenu { CardActions(card: step, leaf: true) }
    }
}

/// 右边：一个叶子任务此刻的样子。完成了是笑着的吉祥物；交给了会话是随状态换的吉祥物（在做时轻轻浮动）、一句话与"打开会话"；
/// 还没开始是挥手的吉祥物与输入框（`DraftComposer`）。
private struct LeafDetail: View {
    let leaf: Card
    let draft: Card?
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
                let look = Look(shown, line: PiProgress.note(of: state, failure: shown.undelivered(item.delivery)?.failure))
                hero(look.mascot, floats: look.floats, title: look.title, note: look.note)
                openSession(state.sessionID, primary: true)
            } else {
                hero(.hello, floats: false, title: "交给 Agent 做这件事", note: nil)
                DraftComposer(leaf: leaf, draft: draft)
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
                .foregroundStyle(primary ? palette.onSignature : palette.ink)
                .padding(.horizontal, 28).frame(height: 40)
                .background(primary ? palette.signatureFill : palette.fill, in: .capsule)
                .shadow(color: palette.signature.opacity(primary && !palette.dark ? 0.25 : 0), radius: 10, y: 4)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
    }

    /// 会话此刻怎样对应哪张图、哪句话（状态只经 `PiShown` 判定）。
    private struct Look {
        var mascot: Mascot, floats = false, title: String, note: String?

        init(_ shown: PiShown, line: String?) {
            switch shown.status {
            case .working, .delivery, .cueAsking: (mascot, floats, title, note) = (.search, true, shown.status == .cueAsking ? shown.presence : "Agent 正在做", "做完会在这里告诉你")
            case .asking: (mascot, title, note) = (.error, "Agent 在等你回答", line)
            case .failed, .restart: (mascot, title, note) = (.error, shown.label, line)
            case .unread: (mascot, title, note) = (.welcome, "Agent 回复了", "去会话里看看")
            case .ended: (mascot, title, note) = (.clean, "会话结束了", "在会话里说一句会把它叫回来")
            case .interrupted: (mascot, title, note) = (.error, "Agent 被打断了", "在会话里说一句，它接着做")
            case .idle, .resting, .fresh, .unknown: (mascot, title, note) = (.welcome, "Agent 歇着", "去会话里接着说")
            }
        }
    }
}

/// 吉祥物：透明底的图，脚下一圈淡阴影；Agent 在做时轻轻上下浮动（Core Animation，`LoopLayer.float`；减弱动态效果时不动）。
private struct MascotFigure: View {
    let mascot: Mascot
    let floats: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let side: CGFloat = 150

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
            Ellipse().fill(RadialGradient(colors: [.black.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 50))
                .frame(width: 90, height: 12).offset(y: 10)
        }
        .accessibilityHidden(true)
    }
}

/// 还没开始的叶子任务的输入框：一块玻璃，里面是这件事的草稿（任务下的那条提示词，编辑器自动保存，⌘↩ 同"开始"）；
/// 还没有草稿时是一行提示，点了新建一条接着写。左下"绑定会话"开新会话，或绑到本项目一个在跑的会话上（写好的话接进那个会话的回复框，不自动发）。
private struct DraftComposer: View {
    let leaf: Card
    let draft: Card?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft {
                DraftEditor(draft: draft)
            } else {
                Button(action: write) {
                    Text("要 Agent 做什么…").font(Typography.body).foregroundStyle(palette.placeholder)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .padding(.horizontal, 6).padding(.top, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Menu { SessionBindItems(leaf: leaf) } label: {
                    Text("绑定会话").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer(minLength: 0)
                Text("⌘↩").font(Typography.meta).foregroundStyle(palette.ink3)
                Button {
                    if let draft { workspace.handOff(draft) }
                } label: {
                    Text("开始").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.onSignature)
                        .padding(.horizontal, 18).frame(height: 32)
                        .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .disabled(draft.map { CardText($0.body).title.isEmpty && CardText($0.body).images.isEmpty } ?? true)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .glass(in: .rect(cornerRadius: 22), ink: .solid)
    }

    private func write() {
        let id = leaf.id, store = services.store
        workspace.attempt { _ = try await store.createCard(body: "", under: id) }
    }
}

/// 草稿的编辑区：打开时接过键盘；换一条、关浮窗都经 `CardEditing.leave` 写下没保存的字，空白的不留下。
private struct DraftEditor: View {
    let draft: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var editing: CardEditing?

    var body: some View {
        Group {
            if let editing { editing.field(draft, theme: .editor(palette, horizontalInset: 6)) } else { Color.clear }
        }
        .frame(height: 110)
        .task {
            editing = CardEditing(draft, workspace: workspace)
            await NextFrame.wait()
            editing?.handle.focus()
        }
        .onDisappear { editing?.leave() }
    }
}

/// 浮窗一次读出的东西：顶层任务、所在项目、它的步骤、各个叶子的草稿。
nonisolated private struct SheetData: Sendable, Equatable {
    var goal: Card
    var project: Project?
    var steps: [Card]
    /// 叶子任务 → 它的草稿（任务下的那条提示词）。
    var drafts: [UUID: Card]
    /// 已不是一条看得见的任务（删了、归档了、改回了灵感）。
    var gone: Bool { goal.deletedAt != nil || goal.archivedAt != nil || !goal.isTask }
    var progress: TaskProgress? { steps.isEmpty ? nil : TaskProgress(done: steps.filter { $0.status == .done }.count, total: steps.count) }

    /// 右边看的叶子：点过的步骤，否则第一个没完成的步骤，再否则第一个步骤；没有步骤时是任务自己。
    func selected(_ step: UUID?) -> Card {
        steps.first { $0.id == step } ?? steps.first { $0.status != .done } ?? steps.first ?? goal
    }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> SheetData {
        guard let goal = try store.card(id) else { throw CueStoreError.notFound }
        let steps = try store.children(of: id).filter(\.isTask)
        let leaves = Set([id] + steps.map(\.id))
        let drafts = try store.prompts(in: goal.projectID).filter { leaves.contains($0.key) }.compactMapValues(\.first)
        return SheetData(goal: goal, project: try goal.projectID.flatMap { try store.project($0) }, steps: steps, drafts: drafts)
    }
}
#endif
