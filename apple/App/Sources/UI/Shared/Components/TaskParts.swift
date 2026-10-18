import CueStore
import CueText
import SwiftUI


// 任务页（手机推入的纸页、Mac 盖在当前页上的浮窗）的几块：任务是一件要做成的事——标题（`TaskHeading`）与下面要交代给 Agent 的话
// （正文，`Card.rest`）；步骤是次要的一组（`SubtaskList`）。


/// 编辑器写的是正文的哪一段：整条（灵感），或任务标题下面的话（`Card.rest`；标题由 `TaskHeading` 另写，写入时各读库里此刻的另一段）。
nonisolated enum CardTextPart: Sendable {
    case whole, rest

    func text(of card: Card) -> String { self == .whole ? card.body : card.rest ?? "" }

    func write(_ text: String, into card: inout Card) {
        switch self {
        case .whole: card.body = text
        case .rest: card.rest = text
        }
    }
}

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
        TextField("这件事是…", text: $title, palette: palette, axis: .vertical)
            .font(font).foregroundStyle(task.status == .done ? palette.ink3 : palette.ink)
            .lineLimit(1...3).focused($focused)
            .onChange(of: title) { _, next in
                // 标题只有一行：回车结束编辑
                if next.contains("\n") { title = next.replacingOccurrences(of: "\n", with: ""); focused = false }
                save()
            }
            .textFieldStyle(.plain)
            .onAppear {
                title = task.heading
                let store = services.store, id = task.id
                autosave = Autosave(
                    save: { title in try await store.updateCard(id) { $0.body = CueLines.joined(title: title, rest: $0.rest) } }, onError: workspace.fail)
            }
            .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    /// 只换标题那一行：下面的正文在写入的那一刻从库里读（`Card.rest`），与正文编辑各写各的。
    private func save() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != task.heading else { return }
        autosave?.changed(title)
    }
}


/// 步骤：在正文之后的次要一组，可勾的圈与标题（点标题打开）；没有步骤时整组不出现。
/// 步骤不在这里加：Mac 浮窗在它下面接一行"添加步骤"，手机在任务大纲里把任务拖到它上面。
struct SubtaskList: View {
    let detail: TaskDetail?
    let open: (Card) -> Void
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
            ForEach(subtasks) { StepLine(step: $0, open: open) }
        }
        .font(TaskMetrics.font)
        .animation(Motion.quick, value: subtasks.map(\.id))
    }
}

/// 步骤一行：完成圈（`TaskCheckButton`）与标题，点标题打开。
private struct StepLine: View {
    let step: Card
    let open: (Card) -> Void
    @Environment(\.palette) private var palette
    @State private var check = TaskCheck()

    var body: some View {
        let done = check.done(step)
        HStack(spacing: 8) {
            TaskCheckButton(
                task: step, size: TaskMetrics.icon * 0.72, target: CGSize(width: TaskMetrics.icon, height: TaskMetrics.rowHeight), check: $check)
            Button { open(step) } label: {
                Text(step.title)
                    .strikethrough(done, color: palette.ink3)
                    .foregroundStyle(done ? palette.ink3 : palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .animation(Motion.quick, value: done)
    }
}
