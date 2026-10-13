#if os(macOS)
import CueStore
import SwiftUI

/// 项目页的任务：前几条没做完的任务连同它们的步骤，一行一件（可拖动、缩进，同任务面板）；没列出的与最近完成的在纸底写个数，点了在纸里原地展开、
/// 各自开合（规则见 `TaskFold`）。按 ui.md 开合不逐帧挪位置：一步到位、新出现的行淡入。展开后是普通栈：默认折起，打开页面只建前几行；
/// 150 条全展开多约 75M 指令、十几到二十毫秒（Release，`-CuePadTasksOpen` 前后比"页面首访"），还在点开要建内容的预算里，不另做懒加载。
/// 每行行尾一格"下一步"（`TaskRow`、`TaskNext`）：交给的 Agent 要你做什么，或写好了还没开始；要 Agent 做什么在任务浮窗里写。
/// 会话的全部列表在侧栏，这里不另开一栏。
/// 项目还没绑文件夹时，任务下面接一行绑定引导（`ProjectFolderGuide`，有同名建议、正在绑时才出现，见 `FolderGuide.shows`）。
/// 纸与下面的资料、卡片墙同宽；任务限在阅读宽度（`readingWidth`）：行尾的"下一步"跟着这一栏，不在大窗口里甩到一千点开外。
struct FocusBand: View {
    let data: ProjectPageData
    let guide: FolderGuide?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var cardAgents
    @Environment(\.palette) private var palette
    @State private var fold = DebugHooks.preset.taskFold

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
        let hidden = TaskFold.hidden(roots.count, limit: Self.visibleTasks)
        let shown = fold.shown(roots, limit: Self.visibleTasks)
        // 展开出来的行（折起时不在纸上的顶层任务连同步骤）：只有它们淡入，一直在的行不动
        let unfolded = Set(data.tasks.rows(of: Array(shown.dropFirst(Self.visibleTasks))).map(\.id))
        let done = data.taskCounts.done
        // 与任务面板同一种行；行带内边距（悬停的淡底），整列往外让出这一截，字与栏标题对齐
        VStack(alignment: .leading, spacing: 0) {
            TaskOutline(tree: data.tasks, roots: shown) { row in
                let agent = cardAgents.items[row.id]
                TaskRow(
                    task: row.task, session: agent?.state, delivery: agent?.delivery,
                    subtasks: data.subtasks[row.id], hasDraft: data.prompts[row.id] != nil)
                .modifier(FadesIn(active: unfolded.contains(row.id)))
            }
            if hidden > 0 || done > 0 {
                HStack(spacing: 6) {
                    if hidden > 0 { toggle(TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, \.showsAll) }
                    if hidden > 0, done > 0 { Dot() }
                    if done > 0 { toggle(TaskCopy.done(done), open: fold.showsDone, \.showsDone) }
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .padding(.horizontal, TaskRow.inset + TaskRow.ringColumn + TaskRow.columnGap).padding(.vertical, 6)
            }
            if fold.showsDone {
                // 同任务面板里已完成的行：淡一档，点圆圈回到待办
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.done) { TaskRow(task: $0) }
                }
                .modifier(FadesIn(active: true))
            }
            NewTaskField(project: data.project?.id).padding(.top, 2)
        }
        .padding(.horizontal, -TaskRow.inset)
    }

    /// 纸底展开或收起的一格：位置一步到位（不让大纲自己的挪位动画接手），新出现的行由 `FadesIn` 淡入。
    private func toggle(_ title: String, open: Bool, _ key: WritableKeyPath<TaskFold, Bool>) -> some View {
        Button {
            withTransaction(\.disablesAnimations, true) { fold[keyPath: key].toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "已展开" : "已折叠")
    }
}

/// 出现时淡入（位置已在终点）；减弱动态效果时同样只是淡入。
private struct FadesIn: ViewModifier {
    let active: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!active || shown ? 1 : 0)
            .onAppear { if active { withAnimation(Motion.quick) { shown = true } } }
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
        .buttonStyle(PressStyle())
        // 放在工具栏里时系统默认只显示图标
        .labelStyle(.titleAndIcon)
        .help("回到顶部")
    }
}
#endif
