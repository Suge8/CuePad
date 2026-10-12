#if os(macOS)
import CueStore
import SwiftUI

/// 任务浮窗：点任务（项目页、任务面板、⌘K、归档）或它的一条提示词就在当前页上弹出，不换页。一件事和它的 Agent，一栏从上往下：
/// 标题（就地改）→ 步骤（勾选清单，只有勾和字）→ 这件事的 Agent 此刻怎样（点"打开会话"看全部对话，对话不在这里）→
/// 还没发的草稿 → 底下的输入框：写下一句要对 Agent 说的话（就是一条提示词），⌘↩ 发出，送达就用掉了、成了会话里的一句。
/// 整页的编辑页只给散放的灵感。
struct TaskSheet: View {
    struct Request: Identifiable, Equatable {
        let id: UUID
        /// 输入框里正在写的那条草稿；nil 时取第一条。换它不换浮窗（浮窗按 `id` 认）。
        var prompt: UUID?
    }

    let taskID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents
    @Environment(\.closePanel) private var close
    @State private var data: SheetData?

    private static let size = CGSize(width: 640, height: 600)

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack {
            if let data {
                VStack(alignment: .leading, spacing: 0) {
                    header(data)
                    ScrollView { overview(data) }.scrollBounceBehavior(.basedOnSize)
                    composer(data)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(palette.desk)
        .observing(services.store, id: taskID, into: $data, onError: workspace.fail) { [taskID] in try SheetData.read(taskID, from: $0) }
        // 别处删掉、归档了它，或改回了灵感：浮窗收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
    }

    /// 输入框里的草稿：点过的那条，否则第一条。
    private func draft(_ data: SheetData) -> Card? {
        let prompts = data.detail.prompts
        return prompts.first { $0.id == workspace.openTask?.prompt } ?? prompts.first
    }

    private func header(_ data: SheetData) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: data.project, size: 12)
            Text(data.project?.name ?? CaptureCopy.unfiled)
                .foregroundStyle(data.project.map { Palette.projectTint($0.color) } ?? palette.ink3)
            Spacer(minLength: 12)
            Menu("更多", systemImage: "ellipsis") { CardActions(card: data.task, more: true) }
                .labelStyle(.iconOnly).menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
            Button("关闭", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2)
                .frame(width: 26, height: 26).background(palette.fill, in: .circle).contentShape(.circle)
                .buttonStyle(PressStyle())
                .help("关闭（Esc）")
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
        .padding(.horizontal, 20).frame(height: 48)
    }

    private func overview(_ data: SheetData) -> some View {
        let task = data.task, draft = draft(data)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 4) {
                TaskRingButton(task: task, prompts: data.detail.prompts.count, subtasks: data.detail.progress).padding(.top, 2)
                // 换成另一条任务时重建：标题的草稿只属于那一条
                TaskHeading(task: task).id(task.id)
            }
            .padding(.horizontal, 4)
            Steps(task: task, steps: data.detail.subtasks)
            if let item = agents.items[task.id] { AgentStatus(item: item) }
            // 输入框里那条之外的草稿：点哪条就到输入框里接着写
            let others = data.detail.prompts.filter { $0.id != draft?.id }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "还没发的").padding(.horizontal, TaskRow.inset)
                    ForEach(others) { PromptLine(prompt: $0) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
    }

    /// 底下的输入框：有草稿就是它的编辑区与操作栏；没有时一行"写下一句要对 Agent 说的话"，点了新建一条接着写。
    @ViewBuilder private func composer(_ data: SheetData) -> some View {
        Group {
            if let draft = draft(data) {
                PromptEditor(prompt: draft, task: data.task).id(draft.id)
            } else {
                Button {
                    let id = data.task.id, store = services.store
                    workspace.attempt { workspace.open(try await store.createCard(body: "", under: id)) }
                } label: {
                    Text("写下一句要对 Agent 说的话…").font(Typography.body).foregroundStyle(palette.placeholder)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .padding(.horizontal, 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.paperLit, in: .rect(cornerRadius: 14, style: .continuous))
        .padding([.horizontal, .bottom], 12)
    }
}

/// 步骤：任务里的勾选清单（数据上是挂在这件事下的任务），点圈勾掉、右键是它的菜单；末尾一行添加。没有步骤时只有那一行。
private struct Steps: View {
    let task: Card
    let steps: [Card]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                let done = step.status == .done
                HStack(spacing: TaskRow.columnGap) {
                    Button { workspace.attempt { try await workspace.toggle(step.id) } } label: {
                        TaskRingView(status: step.status, ring: .plain, done: done, size: 13).frame(width: TaskRow.ringColumn)
                    }
                    .buttonStyle(PressStyle(scale: 0.85))
                    .accessibilityLabel(TaskSpeech.toggle(done: done))
                    Text(step.title).font(Typography.body).strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, TaskRow.inset).frame(minHeight: 28)
                .contentShape(.rect)
                .contextMenu { CardActions(card: step) }
                .sensoryFeedback(.success, trigger: step.status) { $1 == .done }
            }
            NewTaskField(project: task.projectID, parent: task.id)
        }
        .animation(Motion.quick, value: steps.map(\.id))
    }
}

/// 这件事的 Agent 此刻怎样：状态标、会话名、状态词与最要紧的一句（`PiRowLine`），右边"打开会话"——全部对话在会话页里看。
private struct AgentStatus: View {
    let item: PiSessionListItem
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let state = workspace.withLiveState(item.state)
        let shown = services.settings.shown(state, delivery: item.delivery)
        let line = PiRowLine.of(state, draft: nil, end: nil, failure: shown.undelivered(item.delivery)?.failure)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PiStateDot(shown: shown, size: 7).frame(width: TaskRow.ringColumn)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    Text(shown.label).font(Typography.meta).foregroundStyle(shown.labelTint(palette))
                }
                if let line { Text(line.speech).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Button { workspace.show(.session(state.sessionID)) } label: {
                HStack(spacing: 3) {
                    Text("打开会话")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
                .padding(.horizontal, 10).frame(height: 26)
                .background(palette.fill, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
        }
        .padding(12)
        .background(palette.paperLit, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// 输入框：草稿的编辑区（自己滚）与操作栏（去处、发给 Agent，⌘↩ 同主钮）。打开时编辑器接过键盘；
/// 换一条、关浮窗都经 `CardEditing.leave` 写下没保存的字，空白的不留下。
private struct PromptEditor: View {
    let prompt: Card
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var editing: CardEditing?

    private static let height: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editing {
                editing.field(prompt, theme: .editor(palette, horizontalInset: 16))
                HStack {
                    SaveStatus(editing: editing).font(Typography.meta)
                    EditorBar(card: prompt, task: task, editing: editing)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(height: Self.height)
        .task {
            editing = CardEditing(prompt, workspace: workspace)
            await NextFrame.wait()
            editing?.handle.focus()
        }
        .onDisappear { editing?.leave() }
    }
}

/// 浮窗一次读出的东西：任务、所在项目、上级（步骤才有）与下级。
nonisolated private struct SheetData: Sendable, Equatable {
    var task: Card
    var project: Project?
    var parent: Card?
    var detail: TaskDetail
    /// 已不是一条看得见的任务（删了、归档了、改回了灵感）。
    var gone: Bool { task.deletedAt != nil || task.archivedAt != nil || !task.isTask }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> SheetData {
        guard let task = try store.card(id) else { throw CueStoreError.notFound }
        return SheetData(
            task: task, project: try task.projectID.flatMap { try store.project($0) },
            parent: try task.parentID.flatMap { try store.card($0) }, detail: try TaskDetail.read(id, from: store))
    }
}
#endif
