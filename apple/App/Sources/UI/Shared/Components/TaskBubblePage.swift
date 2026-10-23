import CueEditor
import CueStore
import SwiftUI

/// 气泡里的一页：这件事本身，或翻到的一步。从上到下：
/// - 顶上一行，看板的说法：这一列的记号与列名（`BoardLaneMark`，列只出自 `TaskBoard.Column.of`），右边"⋯"；翻到一步时左边是回到上级。
///   不写项目：从看板与项目页点开时它就在眼前，Cue 页里提到的任务那一行也写着。
/// - 完成圈与标题、正文：标题是正文的首段，同一个编辑器（`CardEditing` 的 `titled`），从第一帧就在、就可编辑——点哪光标落在哪，
///   点下去字不挪、行高不变、纸不变高（没有"先显示字、点了换输入框"的那一下）。下面没写时第二段写提示。
/// - 子任务（`TaskLine`）。气泡里不建子任务：拆子任务是 Agent 与 Cue 的事，手动的在任务大纲里把任务拖到它下面（`TaskTree`）。
/// 列记号、完成圈、子任务的圈在左边同一列里居中，字都从同一条竖线起（`BubbleMetrics.textLeading`）。
struct TaskBubblePage: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let overview = focus.id == data.goal.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if overview { lane } else { back }
                Spacer(minLength: 8)
                more
            }
            .frame(height: TaskMetrics.rowHeight)
            HStack(alignment: .top, spacing: BubbleMetrics.titleGap) {
                GoalCheck(task: focus, subtasks: overview ? data.progress : nil).padding(.top, BubbleMetrics.ringTop)
                TaskEditor(card: focus, editing: editing).padding(.trailing, BubbleMetrics.textTrailing)
            }
            if overview, !data.steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.steps) { TaskLine(task: $0, step: true) }
                }
                .padding(.leading, BubbleMetrics.stepLead)
                .padding(.top, 4)
                .animation(HandOff.quick, value: data.steps.map(\.id))
            }
        }
    }

    /// 在看板的哪一列；做到第几步看圈，读屏在这里念。
    private var lane: some View {
        HStack(spacing: BubbleMetrics.titleGap) {
            BoardLaneMark(column: data.column, size: BubbleMetrics.laneMark).frame(width: TaskMetrics.chipTarget)
            Text(data.column.title).font(BubbleMetrics.laneFont).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(data.progress.map(TaskCopy.progress) ?? "")
    }

    /// 翻到一步时：回到上级（它的标题）。
    private var back: some View {
        Button { workspace.openTask(data.goal) } label: {
            HStack(spacing: BubbleMetrics.titleGap) {
                Image(.back).font(BubbleMetrics.laneFont).frame(width: TaskMetrics.chipTarget)
                Text(data.goal.title).font(BubbleMetrics.laneFont.weight(.regular)).lineLimit(1)
            }
            .foregroundStyle(palette.ink2)
            .frame(height: TaskMetrics.rowHeight).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("返回 \(data.goal.title)")
    }

    /// "⋯"：任务气泡与纸页共用的那一份（`CardMenu.more`），换项目收在子菜单里。
    private var more: some View {
        Menu { CardActions(card: focus, more: true) } label: {
            Image(.more).font(BubbleMetrics.laneFont).foregroundStyle(palette.ink2)
                .frame(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget).contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(PressStyle(.button)).menuIndicator(.hidden).fixedSize()
        #endif
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
        field(theme).overlay(alignment: .bottomLeading) { BodyHint(editing: editing, inset: theme.verticalInset) }
    }

    @ViewBuilder private func field(_ theme: CueEditorTheme) -> some View {
        #if os(macOS)
        editing.fittedField(card, theme: theme)
        #else
        CardTextField(card: card, editing: editing, theme: theme, fits: true)
        #endif
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
                .font(.custom(CueEditorTheme.taskBodyFace, size: BubbleMetrics.bodySize, relativeTo: .body))
                .foregroundStyle(palette.ink3)
                .padding(.bottom, inset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension CueEditorTheme {
    static let taskBodyFace = "PingFangSC-Regular"

    /// 任务气泡：首段是标题（墨、大一档、加粗；做完了是第三档墨），下面的话小一档、第二档墨。字贴着框的左沿，与子任务行同一条竖线。
    static func task(_ palette: Palette, done: Bool) -> CueEditorTheme {
        var theme = editor(palette, horizontalInset: 0)
        theme.font = Typeface.pingFang(BubbleMetrics.bodySize)
        theme.textColor = CueColor(palette.ink2)
        theme.lineSpacing = 5
        theme.verticalInset = BubbleMetrics.editorInset
        theme.title = Title(font: Typeface.pingFang(BubbleMetrics.titleSize, weight: .semibold), color: CueColor(done ? palette.ink3 : palette.ink), spacing: 6)
        return theme
    }
}
