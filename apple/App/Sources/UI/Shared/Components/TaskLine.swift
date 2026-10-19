import CueStore
import SwiftUI

/// 一条任务或步骤，全 App 只有这一种行（手机任务页与项目页任务纸、Mac 任务面板与项目页任务区）：完成圈（`TaskCheckButton`）、标题，
/// 加一格旁注——上级的步骤做了几个（"1/4"），与"下一步"（`TaskNextMark`：会话的状态标，或还没交出去的叶子的"开始"）。
/// 一行只说一遍状态：进行中是圈的半填，会话在做什么是那个会动的状态标；不写分组标题、不写状态词胶囊（要你管的才写字）。
/// 所在项目由段头说（待办按项目分段，`TaskBoard.todo`），行里不重复；跨项目平铺的（进行中、最近完成）在标题末尾跟一个项目的小图标，
/// 跟着标题一起折行，不占旁注那一列（读屏念项目名，Mac 悬停写全名）。
/// 步骤（`step`）比上级小一档：字小一号、圈小一号，缩进到圈对着上级标题的起点（`TaskOutline.indentWidth`），层级靠对齐读出来，不靠线。
/// 旁注的位置：iPhone 在行尾（屏窄，行尾就在眼前）；iPad 宽栏与 Mac 紧跟标题（放在行尾时宽窗口里离标题太远，一眼看不到）。
/// `spelled`（手机任务页进行中的顶层叶子）："下一步"写成标题下的第二行，状态词或"开始"一直写出来（`TaskNextMark.spelled`）。
/// 点圈完成（`TaskCheck`），点行的其余地方打开任务（手机推入任务页，Mac 弹出任务浮窗）。Mac 右键是 `CardActions`；
/// 手机长按直接拖动（`TaskOutline`），不挂长按菜单：系统长按菜单弹出后，把预览往下拉是收起菜单、拖不起来，
/// 往下面的组或项目段拖就做不到。菜单那几项各有入口：完成点圈、删除轻扫、归档在任务页的"⋯"。
/// Mac 上指针停在行上时铺行的淡底（`RowStyle`），"开始"与状态词这时才露出来（`TaskNextMark` 读 `rowHovered`）。
struct TaskLine: View {
    let task: Card
    /// 步骤进度（有它的不是叶子，不给"开始"）。
    var subtasks: TaskProgress?
    /// 是某条任务的步骤（大纲里缩进的那一级）。
    var step = false
    /// 跨项目平铺时（进行中、最近完成）给出所在项目，标题末尾画它的小图标；分了段的地方不给。
    var project: Project?
    /// "下一步"写成标题下的第二行（有步骤的上级不算：它的旁注是步骤数）。
    var spelled = false
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
        let next = workspace.next(for: task, in: agents, steps: subtasks)
        let done = check.done(task)
        framed(line(next: next, done: done))
            // 读屏把一行当一个元素："任务内容，步骤 1/4，项目，下一步"，值是状态（文案见 TaskSpeech）；默认动作勾选（与圈同一个动作）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([task.title, subtasks.map(TaskCopy.progress), project?.name, next?.speech].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(TaskSpeech.value(done ? .done : task.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(check.phase == .pending ? "撤销完成" : TaskSpeech.toggle(done: done))
            .accessibilityAction { workspace.tap($check, task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false) }
            .accessibilityActions {
                Button("打开", action: open)
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
        let title = titled(done: done)
            .font(step ? TaskMetrics.stepFont : TaskMetrics.lineFont)
            .lineLimit(titleLines)
        // 旁注不让：标题先折行、再截断，状态词总是完整的
        let below = spelled && subtasks == nil && next != nil && !done
        let side = HStack(alignment: .firstTextBaseline, spacing: 8) { notes(next: next, done: done, spelled: below) }.fixedSize()
        // 圈与旁注都对着标题第一行（`TaskRingView` 的基线），标题折成两行也不落到中间
        return HStack(alignment: .firstTextBaseline, spacing: TaskMetrics.columnGap) {
            ring(next: next)
            if stacked || below {
                // 辅助字号、写成第二行时：旁注换到标题下面，不与标题抢一行
                VStack(alignment: .leading, spacing: 2) { title; side }
                    .padding(.vertical, Self.titlePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if inline {
                title.padding(.vertical, Self.titlePadding)
                side.padding(.leading, 8)
                Spacer(minLength: 0)
            } else {
                title.padding(.vertical, Self.titlePadding).frame(maxWidth: .infinity, alignment: .leading)
                side.padding(.leading, 8)
            }
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        .animation(Motion.quick, value: done)
    }

    /// 标题，跨项目时末尾跟所在项目的小图标（拼进同一段字：随标题折行，基线对齐）。
    private func titled(done: Bool) -> Text {
        let title = Text(task.title.textGlyphs).strikethrough(done, color: palette.ink3).foregroundStyle(done ? palette.ink3 : palette.ink)
        guard let project else { return title }
        let glyph = Text(Image(ProjectGlyph.icon(project))).font(Self.projectGlyph)
            .foregroundStyle(done ? palette.ink3 : palette.project(project.color))
        return Text("\(title)  \(glyph)")
    }

    private func ring(next: TaskNext?) -> some View {
        let size = step ? TaskMetrics.stepRing : TaskMetrics.ring
        let target = CGSize(width: TaskMetrics.ringColumn, height: Self.ringTarget)
        #if os(macOS)
        return TaskCheckButton(task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false, size: size, target: target, check: $check, rowTap: open)
        #else
        return TaskCheckButton(task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false, size: size, target: target, check: $check)
        #endif
    }

    /// 旁注：上级的步骤数与"下一步"；做完的不写。
    @ViewBuilder private func notes(next: TaskNext?, done: Bool, spelled: Bool) -> some View {
        if !done, let subtasks {
            Text("\(subtasks.done)/\(subtasks.total)").font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
        }
        if !done, let next { TaskNextMark(next: next, spelled: spelled).transition(.opacity) }
    }

    private func open() {
        #if os(macOS)
        workspace.open(task)
        #else
        navigation.push(.card(task.id))
        #endif
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
    private static let projectGlyph = Font.caption.weight(.medium)

    /// 长按提起的那一行的外形：与列表那张纸同一个圆角。
    private static let liftRadius: CGFloat = 16

    private func framed(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture(perform: open)
            .contentShape(.dragPreview, .rect(cornerRadius: Self.liftRadius, style: .continuous))
    }
    #else
    private var inline: Bool { true }
    private var stacked: Bool { false }
    private var titleLines: Int { 1 }
    private static let titlePadding: CGFloat = 0
    private static let ringTarget: CGFloat = 15
    private static let projectGlyph = Font.system(size: 11, weight: .medium)

    private func framed(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .row(hovers: true)
            .environment(\.rowHoverPreset, DebugHooks.hovers(task.body))
            .onTapGesture(perform: open)
            .contextMenu { CardActions(card: task, leaf: subtasks == nil) }
            // 只给带项目图标的行挂悬停提示：每行一块提示的跟踪区，滚动时跟着重算
            .background { if let project { Color.clear.help(project.name) } }
            .padding(.vertical, 1)
    }
    #endif
}

/// 任务行上"下一步"那一格（`TaskNext`），Mac 与手机同一份，不垫底、不成胶囊——一屏可能有十几格，胶囊排成一列就成了一墙按钮：
/// 会话那边的事是会话状态标（`PiStateDot`，在做时那条心电线自己会动），要你管的（等你确认、出错、没送到）旁边写状态词，点了打开会话；
/// 还没交出去的叶子是一个"▶"，点了把任务的正文交给 Agent（Mac 直接交出，手机浮起发给 Agent 的输入框带着它）。
/// Mac 上指针停在这一行时（`rowHovered`）"▶ 开始"以靛青露出来、状态标旁写出状态词；没停时"开始"不画（签名色只给焦点，ui.md）。
/// `spelled`：写成标题下的第二行（`TaskLine.spelled`），状态词与"开始"一直写出来、贴着左边。
struct TaskNextMark: View {
    let next: TaskNext
    var spelled = false
    @Environment(\.rowHovered) private var lit
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        if shows {
            Button(action: follow) { label }
                .buttonStyle(PressStyle())
                .help(help)
                .accessibilityLabel(next.speech)
                .accessibilityHint(help)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            switch next {
            case .agent(let shown, let session):
                PiStateDot(shown: shown, size: Self.dot).relaySpot(session: session.sessionID)
                if shown.needsYou || lit || spelled { Text(shown.label).foregroundStyle(shown.labelTint(palette)) }
            case .start:
                Image(.start).font(Self.glyph)
                #if os(macOS)
                Text("开始").fontWeight(.semibold)
                #else
                if spelled { Text("开始") }
                #endif
            }
        }
        .font(TaskMetrics.caption)
        // 没亮起的"▶"与待办的圈同一个淡墨：它是这一行可以做的事，不是要你看的事
        .foregroundStyle(starts ? (lit ? palette.signature : palette.ink3) : palette.ink2)
        .lineLimit(1).fixedSize()
        // 点按区比图形宽；图形贴着行的那一边（手机行尾的一列右缘对齐，紧跟标题时靠左），不在点按区里居中
        .frame(minWidth: Self.target, minHeight: spelled ? nil : Self.target, alignment: spelled ? .leading : edge)
        .contentShape(.rect)
        .animation(Motion.quick, value: lit)
    }

    private var starts: Bool { if case .start = next { true } else { false } }

    #if os(macOS)
    /// "开始"只在指针停在这一行时出现。
    private var shows: Bool { !starts || lit }
    private var edge: Alignment { .leading }
    private static let dot: CGFloat = 6
    private static let glyph = Font.system(size: 8, weight: .bold)
    private static let target: CGFloat = 20
    #else
    private var shows: Bool { true }
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 跟着 `TaskLine` 的排法：手机行尾一列时贴右，紧跟标题或换到标题下面时贴左。
    private var edge: Alignment { sizeClass == .regular || typeSize.isAccessibilitySize ? .leading : .trailing }
    private static let dot: CGFloat = 7
    /// 跟着动态字体走：辅助字号下与旁边的字一起放大。
    private static let glyph = Font.caption2.weight(.bold)
    private static let target: CGFloat = TaskMetrics.chipTarget
    #endif

    private var help: String {
        switch next {
        case .agent: "打开这件事的 Agent 会话"
        case .start: "把任务的正文交给 Agent，开始做"
        }
    }

    private func follow() {
        #if os(macOS)
        workspace.follow(next)
        #else
        navigation.follow(next, store: services.store)
        #endif
    }
}

#if os(macOS)
extension Workspace {
    /// 去"下一步"：打开会话，或把任务的正文交给 Agent。
    func follow(_ next: TaskNext) {
        switch next {
        case .agent(_, let session): show(.session(session.sessionID))
        case .start(let leaf): handOff(leaf)
        }
    }
}
#else
extension Navigation {
    /// 去"下一步"：推入会话页，或浮起发给 Agent 的输入框带着这条任务。
    func follow(_ next: TaskNext, store: CueStore) {
        switch next {
        case .agent(_, let session): openSession(session.id, sessionID: session.sessionID, store: store)
        case .start(let leaf): handToAgent(leaf)
        }
    }
}
#endif

/// 看板一组的标题（手机任务页、Mac 任务面板）："进行中 3"、"待办 11"。
struct TaskGroupHeader: View {
    let title: String
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Self.font).foregroundStyle(palette.ink)
            Text("\(count)").font(Self.countFont).monospacedDigit().foregroundStyle(palette.ink3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private static let font = Typography.secondary.weight(.semibold)
    private static let countFont = Typography.meta
    #else
    private static let font = Font.headline
    private static let countFont = Font.subheadline
    #endif
}

/// 待办里按项目分的一段的段头：项目图标、名字与这一段的条数；未分类是托盘图标与"未分类"。比组标题小一级。
struct TaskSectionHeader: View {
    let project: Project?
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ProjectGlyph(project: project, size: Self.glyph)
            Text(project?.name ?? CaptureCopy.unfiled).foregroundStyle(palette.ink2)
            Text("\(count)").monospacedDigit().foregroundStyle(palette.ink3)
        }
        .font(Self.font)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private static let font = Typography.meta
    private static let glyph: CGFloat = 10
    #else
    private static let font = Font.footnote.weight(.semibold)
    private static let glyph: CGFloat = 11
    #endif
}
