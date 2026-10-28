import CueStore
import SwiftUI

/// 一条任务或子任务，列表里只有这一种行（手机项目页任务纸、Mac 项目页任务区；任务看板是卡，`BoardTaskCard`）：完成圈（`TaskCheckButton`）、标题，
/// 加一格旁注——"下一步"（`TaskNextMark`：会话的状态标，或还没交出去的叶子的"开始"）与进行中的任务多久（`TaskPace`："约 N 分钟""12 分钟"，次要墨色）。
/// 一行只说一遍状态：进行中是圈的半填，子任务做到哪是圈的分段（`TaskRingView`，所以不写"1/4"），会话在做什么是那个会动的状态标；
/// 不写分组标题、不写状态词胶囊。要你管的（`BoardPulse`：`PiShown.speaksOnTask` 与快满的上下文）才写状态词，它占时间那一格的位置。
/// 已完成的不划线、标题淡一档；点圈后停留的那一下（`TaskCheck`）划线，看得清刚勾掉的是哪条。
/// 子任务（`step`）比上级小一档：字小一号、圈小一号，缩进到圈对着上级标题的起点（`TaskOutline.indentWidth`），层级靠对齐读出来，不靠线。
/// 旁注的位置：iPhone 在行尾（屏窄，行尾就在眼前）；iPad 宽栏与 Mac 紧跟标题（放在行尾时宽窗口里离标题太远，一眼看不到）。
/// 标题优先：窄处行尾放不下时让位（`TaskLineLayout`），先丢时间、再丢没写状态词的标，要你管的状态词总留着。
/// 点圈完成（`TaskCheck`），点行的其余地方按 `Workspace.enter`：开工了的叶子进它的会话，其余打开任务气泡（气泡里的子任务行是翻到这一项）。
/// Mac 右键是 `CardActions`；手机长按直接拖动（`TaskOutline`），不挂长按菜单：系统长按菜单弹出后，把预览往下拉是收起菜单、拖不起来，
/// 往下面的组或项目段拖就做不到。菜单那几项在左滑里：删除在最外侧，其余在"更多"长出的气泡里（`CardMorePanel`）。
/// Mac 上指针停在行上时铺行的淡底（`RowStyle`），还没交出去的叶子的"开始"这时才浮在行尾（`hoverReveal`，不占排版，标题与时间一个字都不挪）。
struct TaskLine: View {
    let task: Card
    /// 子任务进度（有它的不是叶子，不给"开始"）。
    var subtasks: TaskProgress?
    /// 是某条任务的子任务（大纲里缩进的那一级）。
    var step = false
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    #endif

    var body: some View {
        let next = workspace.next(for: task, in: agents, steps: subtasks)
        let done = check.done(task)
        framed(line(next: next, done: done))
            .taskSpoken(task, subtasks: subtasks, next: next, aside: task.isPinned ? String(localized: "已置顶") : nil, check: $check, open: open) { start(next) }
    }

    private func line(next: TaskNext?, done: Bool) -> some View {
        // 置顶的顶层任务标题前一枚图钉（看板上同一个，`BoardPin`）
        let name = Text(task.title.textGlyphs)
        let title = (task.isPinned ? Text("\(Text(Image(.pin)).foregroundStyle(palette.ink3)) \(name)") : name).strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(titleInk)
            .font(step ? TaskMetrics.stepFont : TaskMetrics.lineFont)
            .lineLimit(titleLines)
        // 圈与旁注都对着标题第一行（`TaskRingView` 的基线），标题折成两行也不落到中间
        return HStack(alignment: .firstTextBaseline, spacing: TaskMetrics.columnGap) {
            ring(next: next)
            if stacked {
                // 辅助字号时：旁注换到标题下面，不与标题抢一行
                VStack(alignment: .leading, spacing: 2) {
                    title
                    HStack(alignment: .firstTextBaseline, spacing: TaskLineLayout.gap) { notes(next: next, done: done) }.fixedSize()
                }
                .padding(.vertical, Self.titlePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TaskLineLayout(trailing: !inline) {
                    title.padding(.vertical, Self.titlePadding)
                    notes(next: next, done: done)
                }
            }
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        #if os(macOS)
        .hoverReveal(when: !done && next.map { !Self.inlines($0) } ?? false) { if let next { TaskNextMark(next: next).padding(.leading, 4) } }
        #endif
        .animation(Motion.fade, value: done)
    }

    private func ring(next: TaskNext?) -> some View {
        let size = step ? TaskMetrics.stepRing : TaskMetrics.ring
        let target = CGSize(width: TaskMetrics.ringColumn, height: Self.ringTarget)
        #if os(macOS)
        return TaskCheckButton(task: task, subtasks: subtasks, next: next, size: size, target: target, check: $check, rowTap: open)
        #else
        return TaskCheckButton(task: task, subtasks: subtasks, next: next, size: size, target: target, check: $check)
        #endif
    }

    /// 标题的墨：点圈停留的那一下最淡（还划线），已完成的淡一档。
    private var titleInk: Color {
        if check.phase != .idle { return palette.ink3 }
        return task.status == .done ? palette.ink2 : palette.ink
    }

    /// 旁注："下一步"、快满的上下文与多久；做完的不写，要你管的状态词写出来时不写多久。放不下时谁先让（`TaskLineLayout.yields`）：
    /// 先是时间，再是没写状态词的标。
    @ViewBuilder private func notes(next: TaskNext?, done: Bool) -> some View {
        let pulse = workspace.pulse(for: task, lead: nil, in: agents)
        if !done, let next, Self.inlines(next) { TaskNextMark(next: next).yields(first: false, ever: !next.speaks).transition(.opacity) }
        if !done, !(next?.speaks ?? false), let meter = pulse.fullContext { ContextFact(meter: meter).font(TaskMetrics.caption).fixedSize() }
        if !done, !pulse.speaks, let pace = TaskPace.of(task, steps: subtasks) {
            Group {
                switch pace {
                case .left(let seconds): Text(TaskPace.left(seconds))
                case .ran(let since): LiveText(style: PiClock.Elapsed(since: since))
                }
            }
            .font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink3)
            .yields(first: true)
        }
    }

    /// "下一步"排在行里还是悬停才浮出来：Mac 上"开始"只在悬停时浮在行尾（`hoverReveal`）。
    private static func inlines(_ next: TaskNext) -> Bool {
        #if os(macOS)
        if case .start = next { return false }
        #endif
        return true
    }

    private func open() { workspace.enter(task, leaf: subtasks == nil, in: agents) }

    private func start(_ next: TaskNext?) {
        if let next { workspace.follow(next) }
    }

    #if os(iOS)
    private var inline: Bool { sizeClass == .regular }
    private var stacked: Bool { typeSize.isAccessibilitySize }
    private var titleLines: Int { typeSize.isAccessibilitySize ? 4 : 2 }
    /// 标题折成两行时上下留的白：单行时行高由 44pt 的点按高度撑着。
    private static let titlePadding: CGFloat = 10
    private static let ringTarget: CGFloat = 44

    private func framed(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture(perform: open)
    }
    #else
    private var inline: Bool { true }
    private var stacked: Bool { false }
    private var titleLines: Int { 1 }
    private static let titlePadding: CGFloat = 0
    private static let ringTarget: CGFloat = TaskMetrics.ring

    private func framed(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .row()
            .benchSpot(task.id)
            .onTapGesture(perform: open)
            .contextMenu {
                let leaf = subtasks == nil
                CardActions(card: task, leaf: leaf, opens: workspace.entersSession(task, leaf: leaf, in: agents), session: leaf ? agents.items[task.id]?.state : nil)
            }
            .padding(.vertical, 1)
    }
    #endif
}
