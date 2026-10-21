import CueStore
import SwiftUI

/// 一条任务或步骤，全 App 只有这一种行（手机项目页任务纸、Mac 项目页任务区、任务看板的各列）：完成圈（`TaskCheckButton`）、标题，
/// 加一格旁注——"下一步"（`TaskNextMark`：会话的状态标，或还没交出去的叶子的"开始"）与进行中的任务多久（`TaskPace`："约 N 分钟""12 分钟"，次要墨色）。
/// 一行只说一遍状态：进行中是圈的半填，步骤做到哪是圈的分段（`TaskRingView`，所以不写"1/4"），会话在做什么是那个会动的状态标；
/// 不写分组标题、不写状态词胶囊。要你管的（`BoardPulse`：`PiShown.speaksOnTask` 与快满的上下文）才写状态词，它占时间那一格的位置；
/// 看板推进中的行尾按档写（在跑的是状态标加时长，歇着的只写时长、标题淡一档，`BoardPulse.showsMark`）。
/// 已完成的不划线、标题淡一档；点圈后停留的那一下（`TaskCheck`）划线，看得清刚勾掉的是哪条。
/// 看板上上级收成一行（`lead`）：状态看此刻干活的叶子；行尾贴右，项目与成果图写在行尾（`BoardLook`）。
/// 步骤（`step`）比上级小一档：字小一号、圈小一号，缩进到圈对着上级标题的起点（`TaskOutline.indentWidth`），层级靠对齐读出来，不靠线。
/// 旁注的位置：iPhone 在行尾（屏窄，行尾就在眼前）；iPad 宽栏与 Mac 紧跟标题（放在行尾时宽窗口里离标题太远，一眼看不到）。
/// 标题优先：窄的看板列里行尾放不下时让位（`TaskLineLayout`），先丢时间、再丢没写状态词的标，要你管的状态词总留着。
/// 点圈完成（`TaskCheck`），点行的其余地方打开任务气泡（`Workspace.openTask`；气泡里的步骤行是翻到这一步）；看板推进中的行点了进此刻干活的会话
/// （"下一步"是会话时，没有会话的仍开气泡），Mac 右键菜单第一项"打开任务"。Mac 右键是 `CardActions`；
/// 手机长按直接拖动（`TaskOutline`），不挂长按菜单：系统长按菜单弹出后，把预览往下拉是收起菜单、拖不起来，
/// 往下面的组或项目段拖就做不到。菜单那几项各有入口：完成点圈、删除轻扫、归档在任务气泡的"⋯"。
/// Mac 上指针停在行上时铺行的淡底（`RowStyle`），还没交出去的叶子的"开始"这时才浮在行尾（`hoverReveal`，不占排版，标题与时间一个字都不挪；看板上盖住行尾的项目图标）。
struct TaskLine: View {
    let task: Card
    /// 步骤进度（有它的不是叶子，不给"开始"）。
    var subtasks: TaskProgress?
    /// 是某条任务的步骤（大纲里缩进的那一级）。
    var step = false
    /// 此刻干活的叶子（看板上收成一行的上级，`TaskBoard.Item.leaf`）：会话状态看它。
    var lead: Card?
    /// 在任务看板上（`BoardColumn` 给）。
    var board: BoardLook?
    @State private var check = TaskCheck()
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    #else
    @Environment(\.taskStructure) private var structure
    #endif

    var body: some View {
        let next = workspace.next(for: task, lead: lead, in: agents, steps: subtasks)
        let done = check.done(task)
        framed(line(next: next, done: done), next: next)
            // 读屏把一行当一个元素："任务内容，步骤 1/4，下一步"，值是状态（文案见 TaskSpeech）；默认动作勾选（与圈同一个动作）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([task.title, subtasks.map(TaskCopy.progress), next?.speech].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(TaskSpeech.value(done ? .done : task.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(check.phase == .pending ? "撤销完成" : TaskSpeech.toggle(done: done))
            .accessibilityAction { workspace.tap($check, task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false) }
            .accessibilityActions {
                Button("打开", action: open)
                if let board, let shot = board.shot { Button("看成果") { board.openShot(BoardShot.opening(shot, group: task.id.uuidString)) } }
                switch next {
                case .start: Button("开始") { start(next) }
                case .agent: Button("看 Agent 的近况") { start(next) }
                case nil: EmptyView()
                }
                #if os(macOS)
                RowActionButtons(actions: [CardMenu.Item.indent, .outdent].compactMap { $0.rowAction(on: task, in: workspace, structure: structure) })
                #endif
            }
    }

    private func line(next: TaskNext?, done: Bool) -> some View {
        let title = Text(task.title.textGlyphs).strikethrough(check.phase != .idle, color: palette.ink3).foregroundStyle(titleInk(next))
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
                TaskLineLayout(trailing: board != nil || !inline) {
                    title.padding(.vertical, Self.titlePadding)
                    notes(next: next, done: done)
                }
            }
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        #if os(macOS)
        .hoverReveal(when: !done && next.map { !Self.inlines($0) } ?? false) { if let next { TaskNextMark(next: next).padding(.leading, 4) } }
        #endif
        .animation(Motion.quick, value: done)
    }

    private func ring(next: TaskNext?) -> some View {
        let size = step ? TaskMetrics.stepRing : TaskMetrics.ring
        let target = CGSize(width: TaskMetrics.ringColumn, height: Self.ringTarget)
        #if os(macOS)
        return TaskCheckButton(task: task, subtasks: subtasks, next: next, size: size, target: target, check: $check) { tapRow(next) }
        #else
        return TaskCheckButton(task: task, subtasks: subtasks, next: next, size: size, target: target, check: $check)
        #endif
    }

    /// 标题的墨：点圈停留的那一下最淡（还划线），已完成的与看板上歇着的（`BoardPulse.Tier.resting`）淡一档。
    private func titleInk(_ next: TaskNext?) -> Color {
        if check.phase != .idle { return palette.ink3 }
        if task.status == .done || board?.advancing == true && workspace.pulse(for: task, lead: lead, in: agents).tier == .resting { return palette.ink2 }
        return palette.ink
    }

    /// 旁注："下一步"、快满的上下文与多久；做完的不写，要你管的状态词写出来时不写多久。放不下时谁先让（`TaskLineLayout.yields`）：
    /// 先是时间，再是没写状态词的标。看板上行尾最后是成果图与项目小图标（`BoardRowEnd`）。
    @ViewBuilder private func notes(next: TaskNext?, done: Bool) -> some View {
        let pulse = workspace.pulse(for: task, lead: lead, in: agents)
        if !done, let next, Self.inlines(next), board?.advancing != true || pulse.showsMark { TaskNextMark(next: next).yields(first: false, ever: !next.speaks).transition(.opacity) }
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
        if let board, board.hasEnd {
            BoardRowEnd(project: board.project) {
                if let shot = board.shot { BoardShot(shot: shot, group: task.id.uuidString, open: board.openShot) }
            }
        }
    }

    /// "下一步"排在行里还是悬停才浮出来：Mac 上"开始"只在悬停时浮在行尾（`hoverReveal`）。
    private static func inlines(_ next: TaskNext) -> Bool {
        #if os(macOS)
        if case .start = next { return false }
        #endif
        return true
    }

    private func open() { workspace.openTask(task) }

    /// 点行的其余地方：看板推进中的行进此刻干活的会话，其余打开任务气泡。
    private func tapRow(_ next: TaskNext?) {
        if board?.advancing == true, case .agent? = next { return start(next) }
        open()
    }

    private func start(_ next: TaskNext?) {
        guard let next else { return }
        #if os(macOS)
        workspace.follow(next)
        #else
        navigation.follow(next, store: services.store)
        #endif
    }

    #if os(iOS)
    private var inline: Bool { sizeClass == .regular }
    private var stacked: Bool { typeSize.isAccessibilitySize }
    private var titleLines: Int { typeSize.isAccessibilitySize ? 4 : 2 }
    /// 标题折成两行时上下留的白：单行时行高由 44pt 的点按高度撑着。
    private static let titlePadding: CGFloat = 10
    private static let ringTarget: CGFloat = 44

    /// 长按提起的那一行的外形：与列表那张纸同一个圆角。
    private static let liftRadius: CGFloat = 16

    private func framed(_ content: some View, next: TaskNext?) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture { tapRow(next) }
            .contentShape(.dragPreview, .rect(cornerRadius: Self.liftRadius, style: .continuous))
    }
    #else
    private var inline: Bool { true }
    private var stacked: Bool { false }
    private var titleLines: Int { 1 }
    private static let titlePadding: CGFloat = 0
    private static let ringTarget: CGFloat = TaskMetrics.ring

    private func framed(_ content: some View, next: TaskNext?) -> some View {
        content
            .contentShape(.rect)
            .row()
            .benchSpot(task.id)
            .onTapGesture { tapRow(next) }
            .contextMenu {
                if board?.advancing == true {
                    Button("打开任务", icon: .task, action: open)
                    Divider()
                }
                CardActions(card: task, leaf: subtasks == nil)
            }
            .padding(.vertical, 1)
    }
    #endif
}
