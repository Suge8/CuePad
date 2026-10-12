#if os(macOS)
import CueStore
import SwiftUI

/// 项目页的任务：前几条没做完的顶层任务连同子任务与各自的提示词（可拖动、缩进，同任务面板；没列出的与已完成的在底部写个数）。
/// 一个任务一个 Agent 会话，Agent 此刻在做什么写在各自的任务行里（`TaskRow`），会话的全部列表在侧栏，这里不另开一栏。
/// 项目还没绑文件夹时，任务下面接一行绑定引导（`ProjectFolderGuide`，有同名建议、正在绑时才出现，见 `FolderGuide.shows`）。
/// 纸与下面的资料、卡片墙同宽；任务限在阅读宽度（`readingWidth`）：行尾的折起箭头与进度跟着这一栏，不在大窗口里甩到一千点开外。
struct FocusBand: View {
    let data: ProjectPageData
    let guide: FolderGuide?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var cardAgents
    @Environment(\.palette) private var palette

    private static let visibleTasks = 4
    private static let readingWidth: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "任务", systemImage: "checklist")
            taskRows
            if let project = data.project, !workspace.hasFolder(project.id), guide?.shows(project.id, in: .inset) == true {
                ProjectFolderGuide(project: project, guide: guide, style: .inset).padding(.top, 8)
            }
        }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .paper(radius: 18)
    }

    @ViewBuilder private var taskRows: some View {
        let roots = data.tasks.roots
        // 与任务面板同一种行；行带内边距（悬停的淡底），整列往外让出这一截，字与栏标题对齐
        VStack(alignment: .leading, spacing: 0) {
            TaskOutline(
                tree: data.tasks, roots: Array(roots.prefix(Self.visibleTasks)), folds: { TaskRow.folds($0, prompts: data.prompts) }
            ) { row in
                let agent = cardAgents.items[row.id]
                TaskRow(
                    task: row.task, depth: row.depth, session: agent?.state, delivery: agent?.delivery,
                    subtasks: data.subtasks[row.id], prompts: data.prompts[row.id] ?? [], expanded: row.isExpanded)
            }
            if let more = TaskCopy.more(hidden: roots.count - Self.visibleTasks, done: data.taskCounts.done) {
                Button { workspace.showsTasks = true } label: { Text(more) }
                    .buttonStyle(.plain).font(Typography.meta).foregroundStyle(palette.ink3)
                    .padding(.horizontal, TaskRow.inset + TaskRow.ringColumn + TaskRow.columnGap).padding(.vertical, 6)
            }
            NewTaskField(project: data.project?.id).padding(.top, 2)
        }
        .padding(.horizontal, -TaskRow.inset)
    }
}

/// 下滚后收成的悬浮标题：一块玻璃写项目名与没做完的任务数；点一下回到顶部。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: scrollToTop) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ProjectGlyph(project: data.project, size: 13)
                    Text(data.project?.name ?? CaptureCopy.unfiled).font(Typography.toolbarTitle).lineLimit(1)
                }
                Label(data.taskCounts.open > 0 ? "任务 \(data.taskCounts.open)" : "任务", systemImage: "checklist").foregroundStyle(palette.ink2)
            }
            .font(Typography.toolbarLabel)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16).frame(height: Spacing.toolbarControl)
            .glass(in: .capsule, interactive: true, ink: .legible)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        // 放在工具栏里时系统默认只显示图标
        .labelStyle(.titleAndIcon)
        .help("回到顶部")
    }
}
#endif
