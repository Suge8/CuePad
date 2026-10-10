import CueStore
import CueText
import SwiftUI


// 任务页（手机浮窗、Mac 整页）的几块：任务是一件要做成的事——标题与一句说明（`TaskHeading`）；
// 要交给 Agent 的话是挂在它下面的提示词，一张一张卡（`PromptList`），是这一页的主体；子任务是次要的一组（`SubtaskList`）。


/// 任务的标题（单行）与可选的一句说明，就地改、自动保存（存成两行，见 `CueTask`）。标题里按回车跳到说明。
struct TaskHeading: View {
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var note = ""
    @State private var autosave: Autosave?
    @FocusState private var focus: Field?
    private enum Field { case title, note }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("这件事是…", text: $title, axis: .vertical)
                .font(TaskMetrics.title).foregroundStyle(task.status == .done ? palette.ink3 : palette.ink)
                .lineLimit(1...3).focused($focus, equals: .title)
                .onChange(of: title) { _, next in
                    // 标题只有一行：回车去写说明
                    if next.contains("\n") { title = next.replacingOccurrences(of: "\n", with: ""); focus = .note }
                    save()
                }
            TextField("加一句说明（可不填）", text: $note, axis: .vertical)
                .font(TaskMetrics.font).foregroundStyle(palette.ink2)
                .lineLimit(1...3).focused($focus, equals: .note)
                .onChange(of: note) { save() }
        }
        .textFieldStyle(.plain)
        .onAppear {
            let text = CueTask(task.body)
            title = text.title
            note = text.note
            let store = services.store, id = task.id
            autosave = Autosave(save: { body in try await store.updateCard(id) { $0.body = body } }, onError: workspace.fail)
        }
        .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    private func save() {
        let stored = CueTask(title: title, note: note).stored
        guard stored != CueTask(task.body).stored else { return }
        autosave?.changed(stored)
    }
}


/// 子任务：在提示词之后的次要一组，可勾的圈与标题（点标题打开）；没有子任务时整组不出现。
/// 子任务不在这里加：在任务大纲里把任务拖到它上面就成了它的子任务。
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
                Text("子任务").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                if let progress = TaskProgress.subtasks(in: detail?.marks) {
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
                workspace.attempt { try await workspace.toggle(child) }
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


/// 任务页标题左边的完成圈：点它完成（完成的回到待办）；还有没完成的子任务时先问一句，确认后一起完成。
struct TaskRingButton: View {
    let task: Card
    let marks: [ChildMark]?
    var size: CGFloat = TaskMetrics.titleRing
    @Environment(Workspace.self) private var workspace
    @State private var confirming = false

    var body: some View {
        Button {
            if task.status != .done, TaskCopy.hasOpen(.subtasks(in: marks)) { confirming = true } else { toggle() }
        } label: {
            TaskRingView(status: task.status, ring: TaskRing(marks), done: task.status == .done, size: size)
                .frame(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: task.status) { $1 == .done }
        .accessibilityLabel(TaskSpeech.toggle(done: task.status == .done))
        .accessibilityValue([TaskSpeech.value(task.status), TaskSpeech.progress(marks)].compactMap { $0 }.joined(separator: "，"))
        .dialog(TaskCopy.openSubtasks(.subtasks(in: marks)), isPresented: $confirming, buttons: [DialogButton(title: "全部完成") { toggle() }])
    }

    private func toggle() {
        let task = task
        workspace.attempt { try await workspace.toggle(task) }
    }
}


/// 任务行尾的"完成"：提示词都已回复、任务还没完成时出现，点了才完成（任务不自动完成）。行上已写着"全部已回复"，钮只写动作。
struct MarkDoneChip: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Text("完成")
                .font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink)
                .padding(.horizontal, 10).frame(height: TaskMetrics.chipHeight)
                .overlay(Capsule().strokeBorder(palette.hair))
                .frame(minHeight: TaskMetrics.chipTarget).contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("提示词都已回复")
    }
}
