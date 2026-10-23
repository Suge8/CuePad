#if os(iOS)
import CueEditor
import CueStore
import SwiftUI

/// 手机窄屏看一条任务（`PhoneTaskSlot` 挂它；宽屏 iPad 与 Mac 是 `TaskBubble`）：读这件事、开着它的编辑，怎么摆交给容器（`arrange`：
/// 长出来的气泡里下一步跟在内容后面，底部纸页里下一步钉在拇指够得着的底部）。翻页、别处删掉它、关掉都同 `TaskBubble`。
struct PhoneTask<Arranged: View>: View {
    let request: TaskBubble.Request
    @ViewBuilder let arrange: (PhoneTaskPage, BubbleFooter) -> Arranged
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @State private var data: BubbleData?
    /// 翻到的那一步（跟着工作区里开着的这一次）。
    @State private var step: UUID?
    /// 这一页的编辑：页一出现就开着（编辑器从第一帧就在），翻页先写下没保存的字再换。
    @State private var editing: CardEditing?

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack {
            if let data, let editing, editing.cardID == data.focus(step).id {
                let focus = data.focus(step)
                arrange(PhoneTaskPage(data: data, focus: focus, editing: editing), BubbleFooter(data: data, focus: focus, editing: editing))
                    .id(focus.id)
                    .transition(.opacity)
            }
        }
        .animation(HandOff.quick, value: step)
        .observing(services.store, id: request.task, into: $data, onError: workspace.fail) { [task = request.task] in try BubbleData.read(task, from: $0) }
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        .onChange(of: data?.focus(step).id, initial: true) { edit(data?.focus(step)) }
        .onChange(of: live, initial: true) { if let live { step = live.step } }
        .onDisappear { editing?.leave() }
    }

    /// 工作区里开着的正是这一次时的它。
    private var live: TaskBubble.Request? { workspace.openTask?.id == request.id ? workspace.openTask : nil }

    private func edit(_ card: Card?) {
        guard editing?.cardID != card?.id else { return }
        editing?.leave()
        editing = card.map { CardEditing($0, part: .task, workspace: workspace) }
    }
}

/// 一页：这件事本身，或翻到的一步。从上到下：
/// - 顶上一行，看板的说法：这一列的记号与列名（`BoardLaneMark`，列出自 `TaskBoard.Column.of`）、项目小图形与名、"⋯"；翻到一步时左边是回到上级。
/// - 完成圈与标题、正文：标题是正文的首段，同一个编辑器（`CardTextPart.task`），从第一帧就在、就可编辑——点哪光标落在哪，
///   点下去字不挪、行高不变、纸不变高（没有"先显示字、点了换输入框"的那一下）。下面没写时第二段写提示。
/// - 步骤（`TaskLine`）。"⋯"里的添加步骤在末尾浮出一行输入框并聚焦，失焦时没写字就收回；平时不占一行。
/// 圈、列记号、步骤的圈与添加那一行的加号都在左边同一列（`TaskMetrics.ringColumn`）里居中，字都从同一条竖线起。
struct PhoneTaskPage: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var addingStep = false

    var body: some View {
        let overview = focus.id == data.goal.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TaskMetrics.columnGap) {
                if overview { lane } else { back }
                Spacer(minLength: 8)
                more(overview)
            }
            .frame(height: TaskMetrics.rowHeight)
            HStack(alignment: .top, spacing: TaskMetrics.columnGap) {
                GoalCheck(task: focus, subtasks: overview ? data.progress : nil).padding(.top, Self.ringTop)
                TaskEditor(card: focus, editing: editing).padding(.trailing, Self.textTrailing)
            }
            if overview, !data.steps.isEmpty || addingStep {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.steps) { TaskLine(task: $0, step: true) }
                    if addingStep {
                        NewTaskField(project: data.goal.projectID, parent: data.goal.id, autofocus: true) { addingStep = false }
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .padding(.top, 4)
                .animation(HandOff.quick, value: data.steps.map(\.id))
                .animation(HandOff.quick, value: addingStep)
            }
        }
    }

    /// 字的右边留白（"⋯"的点按区贴着纸边，字不贴）。
    private static let textTrailing: CGFloat = 12
    /// 下一步那一条从字的那条竖线起（`arrange` 摆它时用）。
    static let textLeading = TaskMetrics.ringColumn + TaskMetrics.columnGap

    /// 标题第一行的中线对着圈的中线：编辑器上留白 + 半个标题行高 − 半个点按区。
    private static let ringTop: CGFloat = 3

    /// 在看板的哪一列、哪个项目：读屏念成一句。
    private var lane: some View {
        HStack(spacing: 0) {
            BoardLaneMark(column: data.column, size: 20).frame(width: TaskMetrics.ringColumn)
            Text(data.column.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                .padding(.leading, TaskMetrics.columnGap)
            if let project = data.project {
                ProjectGlyph(project: project, size: TaskMetrics.cardGlyph).padding(.leading, 14).padding(.trailing, 5)
                Text(project.name).font(.subheadline).foregroundStyle(palette.ink2)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(data.progress.map(TaskCopy.progress) ?? "")
    }

    /// 翻到一步时：回到上级（它的标题）。
    private var back: some View {
        Button { workspace.openTask(data.goal) } label: {
            HStack(spacing: TaskMetrics.columnGap) {
                Image(.back).font(.subheadline.weight(.semibold)).frame(width: TaskMetrics.ringColumn)
                Text(data.goal.title).font(.subheadline).lineLimit(1)
            }
            .foregroundStyle(palette.ink2)
            .frame(height: TaskMetrics.rowHeight).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("返回 \(data.goal.title)")
    }

    /// "⋯"：添加步骤在最前（只在这件事本身上，步骤下面不再分步），其余是任务气泡与纸页共用的那一份（`CardMenu.more`），换项目收在子菜单里。
    private func more(_ overview: Bool) -> some View {
        Menu {
            if overview {
                Button("添加步骤", icon: .add) { addingStep = true }
                Divider()
            }
            CardActions(card: focus, more: true)
        } label: {
            Image(.more).font(.body.weight(.semibold)).foregroundStyle(palette.ink2)
                .frame(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget).contentShape(.rect)
        }
        .accessibilityLabel("更多")
    }
}

/// 标题与正文的编辑器：高贴着字，整张纸一起滚。
private struct TaskEditor: View {
    let card: Card
    let editing: CardEditing
    @Environment(\.palette) private var palette

    var body: some View {
        let theme = CueEditorTheme.task(palette, done: card.status == .done)
        CardTextField(card: card, editing: editing, theme: theme, fits: true)
            .overlay(alignment: .bottomLeading) { BodyHint(editing: editing, inset: theme.verticalInset) }
    }
}

/// 正文还没写时第二段（空段）上的提示。点它就是点进那一段：不拦点按。只看标题那一行之后有没有字，每敲一个字的开销不随正文变长。
private struct BodyHint: View {
    let editing: CardEditing
    let inset: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        let text = editing.text
        if let newline = text.firstIndex(of: "\n"), text.index(after: newline) == text.endIndex {
            Text("写正文：要 Agent 做什么")
                .font(.custom(CueEditorTheme.taskBodyFace, size: CueEditorTheme.taskBodySize, relativeTo: .body))
                .foregroundStyle(palette.ink3)
                .padding(.bottom, inset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension CueEditorTheme {
    static let taskBodyFace = "PingFangSC-Regular"
    static let taskBodySize: CGFloat = 16

    /// 手机任务浮窗：首段是标题（墨、大一档、加粗；做完了是第三档墨），下面的话小一档、第二档墨。字贴着框的左沿，与步骤行同一条竖线。
    static func task(_ palette: Palette, done: Bool) -> CueEditorTheme {
        var theme = editor(palette, horizontalInset: 0)
        theme.font = Typeface.pingFang(taskBodySize)
        theme.textColor = CueColor(palette.ink2)
        theme.lineSpacing = 5
        theme.verticalInset = 10
        theme.title = Title(font: Typeface.pingFang(20, weight: .semibold), color: CueColor(done ? palette.ink3 : palette.ink), spacing: 6)
        return theme
    }
}
#endif
