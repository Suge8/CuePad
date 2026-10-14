#if os(macOS)
import CueStore
import SwiftUI

/// 项目页的任务：前几条没做完的任务连同它们的步骤，一行一件（可拖动、缩进，同任务面板）；没列出的与最近完成的在纸底写个数，点了在纸里原地展开、
/// 各自开合（规则见 `TaskFold`）。按 ui.md 开合不逐帧挪位置：一步到位、新出现的行淡入（`UnfoldVeil`：一块纸盖住再淡开，不逐行做动画）。
/// 收起其余任务时纸底那一行留在原来的屏幕位置（`TaskFoldAnchor`），长列表底部收起不会跳到卡片墙。
/// 每行行尾一格"下一步"（`TaskRow`、`TaskNext`）：交给的 Agent 要你做什么，或写好了还没开始；要 Agent 做什么在任务浮窗里写。
/// 会话的全部列表在侧栏，这里不另开一栏。
/// 项目还没绑文件夹时，任务下面接一行绑定引导（`ProjectFolderGuide`，有同名建议、正在绑时才出现，见 `FolderGuide.shows`）。
/// 纸与下面的资料、卡片墙同宽；任务限在阅读宽度（`readingWidth`）：行尾的"下一步"跟着这一栏，不在大窗口里甩到一千点开外。
struct FocusBand: View {
    let data: ProjectPageData
    let guide: FolderGuide?
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var cardAgents
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var fold = DebugHooks.preset.taskFold
    /// 折起时纸底那一行的上沿（纸里的坐标）：展开后从这里往下是新出现的行。只在折起时、它挪了才写。
    @State private var foldedTop: CGFloat = 0

    private static let visibleTasks = 4
    /// 没做完的任务（含步骤）有这么多时大纲行按需建：全展开时普通栈要在点开的那一圈把每行都建出、量一遍（150 条约 130ms，Release）。
    /// 按总数定、不按开合定：换栈会让一直在的那几行也跟着重建。
    private static let lazyFrom = 20
    private static let readingWidth: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "任务", systemImage: "checklist")
            taskRows
            if let project = data.project, !workspace.hasFolder(project.id), guide?.shows(project.id, in: .inset) == true {
                ProjectFolderGuide(project: project, guide: guide, style: .inset).padding(.top, 8)
            }
        }
        .debugExposesTaskFold(active: active) { toggle(\.showsAll) }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.band))
        .overlay { if fold.showsAll { UnfoldVeil(top: foldedTop).clipShape(.rect(cornerRadius: Self.radius, style: .continuous)) } }
        .paper(radius: Self.radius)
    }

    private static let band = "taskBand"
    private static let radius: CGFloat = 18

    @ViewBuilder private var taskRows: some View {
        let roots = data.tasks.roots
        let hidden = TaskFold.hidden(roots.count, limit: Self.visibleTasks)
        let shown = fold.shown(roots, limit: Self.visibleTasks)
        let done = data.taskCounts.done
        // 与任务面板同一种行；行带内边距（悬停的淡底），整列往外让出这一截，字与栏标题对齐
        VStack(alignment: .leading, spacing: 0) {
            TaskOutline(tree: data.tasks, roots: shown, lazy: data.tasks.ordered.count >= Self.lazyFrom) { row in
                let agent = cardAgents.items[row.id]
                TaskRow(
                    task: row.task, session: agent?.state, delivery: agent?.delivery,
                    subtasks: data.subtasks[row.id], hasDraft: data.prompts[row.id] != nil)
            }
            if hidden > 0 || done > 0 {
                HStack(spacing: 6) {
                    if hidden > 0 { toggleButton(TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, \.showsAll) }
                    if hidden > 0, done > 0 { Dot() }
                    if done > 0 { toggleButton(TaskCopy.done(done), open: fold.showsDone, \.showsDone) }
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .padding(.horizontal, TaskRow.inset + TaskRow.ringColumn + TaskRow.columnGap).padding(.vertical, 6)
                .taskFoldBar(anchor, folded: !fold.showsAll)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.band)).minY } action: { if !fold.showsAll { foldedTop = $0 } }
            }
            if fold.showsDone {
                // 同任务面板里已完成的行：淡一档，点圆圈回到待办
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.done) { TaskRow(task: $0) }
                }
                .modifier(FadesIn())
            }
            NewTaskField(project: data.project?.id).padding(.top, 2)
        }
        .padding(.horizontal, -TaskRow.inset)
    }

    /// 展开或收起：位置一步到位（不让大纲自己的挪位动画接手），新出现的行由 `UnfoldVeil` 淡入；收起其余任务时滚动在同一步里把纸底这一行留在原处。
    private func toggle(_ key: WritableKeyPath<TaskFold, Bool>) {
        if key == \.showsAll, fold.showsAll { return anchor.collapse($fold, scrolling: $position) }
        withTransaction(\.disablesAnimations, true) { fold[keyPath: key].toggle() }
    }

    private func toggleButton(_ title: String, open: Bool, _ key: WritableKeyPath<TaskFold, Bool>) -> some View {
        Button { toggle(key) } label: {
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

/// 展开其余任务时盖住新出现的那一截（`top` 往下，同纸面的底），出现即淡开：新行一步到位、看上去淡入。一块盖板一个动画，
/// 不逐行挂淡入——逐行在出现时起动画，点开后那一圈要多排一遍几十行的透明度（150 条时多出一圈约 60ms），懒加载的行滚进来时也会再淡一遍。
private struct UnfoldVeil: View {
    let top: CGFloat
    @Environment(\.palette) private var palette
    @State private var shown = true

    var body: some View {
        Rectangle().fill(palette.paperFill)
            .clipShape(Below(top: top))
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { withAnimation(Motion.quick) { shown = false } }
    }
}

/// `top` 往下的那一截。
nonisolated private struct Below: Shape {
    let top: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: max(rect.height - top, 0)))
    }
}

/// 出现时淡入（位置已在终点）；减弱动态效果时同样只是淡入。
private struct FadesIn: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.quick) { shown = true } }
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
