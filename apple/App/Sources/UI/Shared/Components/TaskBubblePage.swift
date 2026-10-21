import CueStore
import CueText
import SwiftUI

/// 气泡里的一页：这件事本身，或翻到的一步。
struct BubblePage: View {
    let data: BubbleData
    let focus: Card
    @Binding var editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let overview = focus.id == data.goal.id
        VStack(alignment: .leading, spacing: 0) {
            if !overview { back }
            HStack(alignment: .top, spacing: BubbleMetrics.gap) {
                // 圈的点按区比图形宽：往左伸进边距，图形与下面各行的圈对齐
                GoalCheck(task: focus, subtasks: overview ? data.progress : nil)
                    .padding(.top, BubbleMetrics.ringNudge).padding(.leading, -BubbleMetrics.ringBleed)
                TaskHeading(task: focus, font: BubbleMetrics.title).id(focus.id)
                more
            }
            if overview { meta }
            BriefField(card: focus, editing: $editing)
                .padding(.leading, BubbleMetrics.indent)
                .padding(.top, BubbleMetrics.section)
            if overview {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.steps) { TaskLine(task: $0, step: true) }
                    NewTaskField(project: data.goal.projectID, parent: data.goal.id)
                }
                .padding(.leading, BubbleMetrics.indent - BubbleMetrics.rowLead)
                .padding(.top, BubbleMetrics.section - 4)
                .animation(Motion.quick, value: data.steps.map(\.id))
            }
            BubbleFooter(data: data, focus: focus, editing: editing)
                .padding(.top, BubbleMetrics.section + 2)
        }
        .padding(BubbleMetrics.padding)
    }

    /// 翻到一步时左上那一行：回到上级（它的标题）。
    private var back: some View {
        Button { workspace.openTask(data.goal) } label: {
            HStack(spacing: 4) {
                Image(.back).font(BubbleMetrics.meta.weight(.semibold))
                Text(data.goal.title).lineLimit(1)
            }
            .font(BubbleMetrics.meta).foregroundStyle(palette.ink2)
            .frame(minHeight: BubbleMetrics.backHeight).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("返回 \(data.goal.title)")
        .padding(.bottom, 4)
    }

    /// 所在项目；做到第几步看圈，读屏在这里念。
    private var meta: some View {
        HStack(spacing: 5) {
            ProjectGlyph(project: data.project, size: BubbleMetrics.glyph)
            Text(data.project?.name ?? "").lineLimit(1)
        }
        .font(BubbleMetrics.meta).foregroundStyle(palette.ink3)
        .padding(.leading, BubbleMetrics.indent).padding(.top, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(data.progress.map(TaskCopy.progress) ?? "")
    }

    private var more: some View {
        Menu { CardActions(card: focus, more: true) } label: {
            Image(.more).font(BubbleMetrics.meta.weight(.bold)).foregroundStyle(palette.ink2)
                .frame(width: BubbleMetrics.moreTarget, height: BubbleMetrics.moreTarget).contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(PressStyle(.button)).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityLabel("更多")
        .padding(.top, -4).padding(.trailing, -8)
    }
}

/// 正文：平时是几行预览（没写时是一行提示），点了就地换成编辑器、接过键盘；开气泡时不建编辑器。
private struct BriefField: View {
    let card: Card
    @Binding var editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if let editing {
            editor(editing)
                .padding(.horizontal, -BubbleMetrics.editorInset)
                .frame(height: BubbleMetrics.editorHeight)
                .background(palette.fill, in: .rect(cornerRadius: BubbleMetrics.editorRadius, style: .continuous))
                .task {
                    await NextFrame.wait()
                    editing.handle.focus()
                }
        } else {
            Button(action: begin) {
                Group {
                    if let rest = card.rest, !rest.isEmpty {
                        Text(CueFormat.plainText(rest)).foregroundStyle(palette.ink2).lineLimit(BubbleMetrics.previewLines)
                    } else {
                        Text("写正文：要 Agent 做什么").foregroundStyle(palette.ink3)
                    }
                }
                .font(BubbleMetrics.body).lineSpacing(BubbleMetrics.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(.wide))
            .accessibilityLabel(card.rest.map { "正文，\(CueFormat.plainText($0))" } ?? "写正文")
            .accessibilityHint("编辑正文")
        }
    }

    private func begin() { editing = CardEditing(card, part: .rest, workspace: workspace) }

    @ViewBuilder private func editor(_ editing: CardEditing) -> some View {
        #if os(macOS)
        editing.field(card, theme: .editor(palette, horizontalInset: BubbleMetrics.editorInset))
        #else
        CardTextField(card: card, editing: editing, theme: .editor(palette, horizontalInset: BubbleMetrics.editorInset))
        #endif
    }
}
