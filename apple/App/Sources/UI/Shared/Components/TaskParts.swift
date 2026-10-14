import CueStore
import CueText
import SwiftUI


// 任务浮窗（手机、Mac 都是盖在当前页上的一层）的几块：任务是一件要做成的事——只有标题（`TaskHeading`）；
// 要发给 Agent 的话是挂在它下面的提示词，一张一张卡（`PromptList`），是这一页的主体；步骤是次要的一组（`SubtaskList`）。


/// 任务的标题（单行），就地改、自动保存。回车结束编辑。
struct TaskHeading: View {
    let task: Card
    /// 任务页、浮窗顶上是大标题；Mac 浮窗左栏里选中的步骤就地改名时是正文字号。
    var font = TaskMetrics.title
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var autosave: Autosave?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("这件事是…", text: $title, axis: .vertical)
            .font(font).foregroundStyle(task.status == .done ? palette.ink3 : palette.ink)
            .lineLimit(1...3).focused($focused)
            .onChange(of: title) { _, next in
                // 标题只有一行：回车结束编辑
                if next.contains("\n") { title = next.replacingOccurrences(of: "\n", with: ""); focused = false }
                save()
            }
            .textFieldStyle(.plain)
            .onAppear {
                title = CueSummary(task.body).title
                let store = services.store, id = task.id
                autosave = Autosave(save: { body in try await store.updateCard(id) { $0.body = body } }, onError: workspace.fail)
            }
            .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    /// 只换标题那一行：正文里若还有别的话（旧版本同步来的），一并写回，由 Store 拆成提示词，不在改标题时丢掉。
    private func save() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != CueSummary(task.body).title else { return }
        autosave?.changed(CueLines.split(task.body).prompt.map { title + "\n" + $0 } ?? title)
    }
}


/// 步骤：在提示词之后的次要一组，可勾的圈与标题（点标题打开）；没有步骤时整组不出现。
/// 步骤不在这里加：Mac 浮窗在它下面接一行"添加步骤"，手机在任务大纲里把任务拖到它上面。
struct SubtaskList: View {
    let detail: TaskDetail?
    let open: (Card) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let subtasks = detail?.subtasks ?? []
        if !subtasks.isEmpty { list(subtasks) }
    }

    private func list(_ subtasks: [Card]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("步骤").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                if let progress = detail?.progress {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                }
            }
            ForEach(subtasks) { row($0) }
        }
        .font(TaskMetrics.font)
        .animation(Motion.quick, value: subtasks.map(\.id))
    }

    private func row(_ child: Card) -> some View {
        HStack(spacing: 8) {
            Button {
                workspace.attempt { try await workspace.toggle(child.id) }
            } label: {
                TaskRingView(status: child.status, ring: .plain, done: child.status == .done, size: TaskMetrics.icon * 0.72)
                    .frame(width: TaskMetrics.icon, height: TaskMetrics.rowHeight).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TaskSpeech.toggle(done: child.status == .done))
            Button { open(child) } label: {
                Text(child.title)
                    .strikethrough(child.status == .done)
                    .foregroundStyle(child.status == .done ? palette.ink3 : palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .sensoryFeedback(.success, trigger: child.status) { $1 == .done }
    }
}


/// 任务页标题左边的完成圈：点它完成（完成的回到待办）；还有没完成的步骤时先问一句，确认后一起完成。
struct TaskRingButton: View {
    let task: Card
    let prompts: Int
    let subtasks: TaskProgress?
    var size: CGFloat = TaskMetrics.titleRing
    @Environment(Workspace.self) private var workspace
    @State private var confirming = false

    var body: some View {
        Button {
            if task.status != .done, TaskCopy.hasOpen(subtasks) { confirming = true } else { toggle() }
        } label: {
            TaskRingView(status: task.status, ring: TaskRing(subtasks), done: task.status == .done, size: size)
                .frame(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: task.status) { $1 == .done }
        .accessibilityLabel(TaskSpeech.toggle(done: task.status == .done))
        .accessibilityValue([TaskSpeech.value(task.status), TaskSpeech.progress(prompts: prompts, subtasks: subtasks)].compactMap { $0 }.joined(separator: "，"))
        .dialog(TaskCopy.openSubtasks(subtasks), isPresented: $confirming, buttons: [DialogButton(title: "全部完成") { toggle() }])
    }

    private func toggle() {
        let task = task
        workspace.attempt { try await workspace.toggle(task.id) }
    }
}
