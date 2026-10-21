import CueStore
import SwiftUI

/// 一条任务或步骤，全 App 只有这一种行（手机项目页任务纸、Mac 项目页任务区、任务看板的各列与等你卡的抬头）：完成圈（`TaskCheckButton`）、标题，
/// 加一格旁注——进行中的任务多久（`TaskPace`："约 N 分钟""已跑 N 分钟"，次要墨色），与"下一步"（`TaskNextMark`：会话的状态标，或还没交出去的叶子的"开始"）。
/// 一行只说一遍状态：进行中是圈的半填，步骤做到哪是圈的分段（`TaskRingView`，所以不写"1/4"），会话在做什么是那个会动的状态标；
/// 不写分组标题、不写状态词胶囊。要你管的（`PiShown.speaksOnTask`）才写状态词，它占时间那一格的位置。
/// 看板上上级收成一行（`lead`）：状态看此刻干活的叶子。所在项目由所在的页或段头说，行里不重复。
/// 步骤（`step`）比上级小一档：字小一号、圈小一号，缩进到圈对着上级标题的起点（`TaskOutline.indentWidth`），层级靠对齐读出来，不靠线。
/// 旁注的位置：iPhone 在行尾（屏窄，行尾就在眼前）；iPad 宽栏与 Mac 紧跟标题（放在行尾时宽窗口里离标题太远，一眼看不到）。
/// 标题优先：窄的看板列里行尾放不下时让位（`TaskLineLayout`），先丢时间、再丢没写状态词的标，要你管的状态词总留着。
/// 点圈完成（`TaskCheck`），点行的其余地方打开任务气泡（`Workspace.openTask`；气泡里的步骤行是翻到这一步）。Mac 右键是 `CardActions`；
/// 手机长按直接拖动（`TaskOutline`），不挂长按菜单：系统长按菜单弹出后，把预览往下拉是收起菜单、拖不起来，
/// 往下面的组或项目段拖就做不到。菜单那几项各有入口：完成点圈、删除轻扫、归档在任务气泡的"⋯"。
/// Mac 上指针停在行上时铺行的淡底（`RowStyle`），"开始"与状态词这时才露出来（`TaskNextMark` 读 `rowHovered`）。
struct TaskLine: View {
    let task: Card
    /// 步骤进度（有它的不是叶子，不给"开始"）。
    var subtasks: TaskProgress?
    /// 是某条任务的步骤（大纲里缩进的那一级）。
    var step = false
    /// 此刻干活的叶子（看板上收成一行的上级，`TaskBoard.Item.leaf`）：会话状态看它。
    var lead: Card?
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
        framed(line(next: next, done: done))
            // 读屏把一行当一个元素："任务内容，步骤 1/4，下一步"，值是状态（文案见 TaskSpeech）；默认动作勾选（与圈同一个动作）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([task.title, subtasks.map(TaskCopy.progress), next?.speech].compactMap { $0 }.joined(separator: "，"))
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
        let title = Text(task.title.textGlyphs).strikethrough(done, color: palette.ink3).foregroundStyle(done ? palette.ink3 : palette.ink)
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
        .animation(Motion.quick, value: done)
    }

    private func ring(next: TaskNext?) -> some View {
        let size = step ? TaskMetrics.stepRing : TaskMetrics.ring
        let target = CGSize(width: TaskMetrics.ringColumn, height: Self.ringTarget)
        #if os(macOS)
        return TaskCheckButton(task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false, running: next?.isRunning ?? false, size: size, target: target, check: $check, rowTap: open)
        #else
        return TaskCheckButton(task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false, running: next?.isRunning ?? false, size: size, target: target, check: $check)
        #endif
    }

    /// 旁注：多久与"下一步"；做完的不写，要你管的状态词写出来时不写多久。放不下时谁先让（`TaskLineLayout.yields`）：先是时间，再是没写状态词的标。
    @ViewBuilder private func notes(next: TaskNext?, done: Bool) -> some View {
        if !done, !(next?.speaks ?? false), let pace = TaskPace.of(task, steps: subtasks) {
            Group {
                switch pace {
                case .left(let seconds): Text(TaskPace.left(seconds))
                case .ran(let since): LiveText(style: TaskPace.Ran(since: since))
                }
            }
            .font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink3)
            .yields(first: true)
        }
        if !done, let next { TaskNextMark(next: next).yields(first: false, ever: !next.speaks).transition(.opacity) }
    }

    private func open() { workspace.openTask(task) }

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
    private static let ringTarget: CGFloat = TaskMetrics.ring

    private func framed(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .row(hovers: true)
            .environment(\.rowHoverPreset, DebugHooks.hovers(task.body))
            .benchSpot(task.id)
            .onTapGesture(perform: open)
            .contextMenu { CardActions(card: task, leaf: subtasks == nil) }
            .padding(.vertical, 1)
    }
    #endif
}

/// 任务行的标题与行尾一次排（`TaskLine`；不用 `ViewThatFits`：它把每个候选都建一遍）：第一格是标题，其后是行尾各格。
/// 标题至少留 `minTitle`（比它短的留它整行）；放不下时行尾按让位的先后收起（`yields`：先是时间，再是没写状态词的标），
/// 写了状态词的（要你管的那件）不让。收起的那格量成零大小、裁掉不画。`trailing`：行尾贴右（手机一列）；否则紧跟标题（iPad 宽栏、Mac）。
/// 行尾各格的首行基线对着标题首行；整块的首行基线就是标题的，外面的圈对着它。
struct TaskLineLayout: Layout {
    let trailing: Bool

    static let gap: CGFloat = 8
    #if os(macOS)
    static let minTitle: CGFloat = 96
    #else
    static let minTitle: CGFloat = 110
    #endif

    /// 行尾一格让位的先后：数大的先让，0 不让。
    struct Yield: LayoutValueKey { static let defaultValue = 0 }

    private struct Plan {
        var title: ProposedViewSize
        var shown: [Bool]
        var sizes: [CGSize]
        var side: CGFloat
        var titleWidth: CGFloat
        /// 各格顶边相对整块顶边的位置（第一格是标题）。
        var tops: [CGFloat]
        var height: CGFloat
    }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> Plan {
        let notes = Array(subviews.dropFirst())
        let sizes = notes.map { $0.sizeThatFits(.unspecified) }
        var shown = notes.map { _ in true }
        func side() -> CGFloat { zip(sizes, shown).reduce(0) { $0 + ($1.1 ? $1.0.width + Self.gap : 0) } }
        let ideal = subviews[0].sizeThatFits(.unspecified).width
        if let width {
            for index in notes.indices.sorted(by: { notes[$0][Yield.self] > notes[$1][Yield.self] }) where notes[index][Yield.self] > 0 {
                if width - side() >= min(ideal, Self.minTitle) { break }
                shown[index] = false
            }
        }
        let room = max((width ?? ideal + side()) - side(), 0)
        let titleWidth = trailing && width != nil ? room : min(ideal, room)
        let title = ProposedViewSize(width: titleWidth, height: nil)
        let titleSize = subviews[0].sizeThatFits(title)
        let baseline = subviews[0].dimensions(in: title)[.firstTextBaseline]
        var tops = [0.0], bottoms = [titleSize.height]
        for (index, note) in notes.enumerated() {
            let top = shown[index] ? baseline - note.dimensions(in: ProposedViewSize(sizes[index]))[.firstTextBaseline] : 0
            tops.append(top)
            bottoms.append(top + (shown[index] ? sizes[index].height : 0))
        }
        let lift = -min(tops.min() ?? 0, 0)
        return Plan(
            title: title, shown: shown, sizes: sizes, side: side(), titleWidth: titleWidth,
            tops: tops.map { $0 + lift }, height: (bottoms.max() ?? 0) + lift)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let plan = plan(proposal.width, subviews)
        return CGSize(width: proposal.width ?? plan.titleWidth + plan.side, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let plan = plan(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + plan.tops[0]), proposal: plan.title)
        var x = trailing ? bounds.maxX - plan.side : bounds.minX + plan.titleWidth
        for (index, note) in subviews.dropFirst().enumerated() {
            guard plan.shown[index] else {
                note.place(at: bounds.origin, proposal: .zero)
                continue
            }
            x += Self.gap
            note.place(at: CGPoint(x: x, y: bounds.minY + plan.tops[index + 1]), proposal: ProposedViewSize(plan.sizes[index]))
            x += plan.sizes[index].width
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, !subviews.isEmpty else { return nil }
        let plan = plan(bounds.width, subviews)
        return bounds.minY + plan.tops[0] + subviews[0].dimensions(in: plan.title)[.firstTextBaseline]
    }
}

extension View {
    /// 任务行行尾的一格（`TaskLineLayout`）：放不下时让位，`first` 的先让；`ever` 为假的不让。
    /// 量自己时是本来的大小，让掉时给零大小、裁掉不画；不让的不裁（等你确认的波纹画在标外面）。
    @ViewBuilder func yields(first: Bool, ever: Bool = true) -> some View {
        if ever {
            fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .layoutValue(key: TaskLineLayout.Yield.self, value: first ? 2 : 1)
        } else {
            fixedSize()
        }
    }
}

/// 任务行上"下一步"那一格（`TaskNext`），Mac 与手机同一份，不垫底、不成胶囊——一屏可能有十几格，胶囊排成一列就成了一墙按钮：
/// 会话那边的事是会话状态标（`PiStateDot`，在做时那条心电线自己会动），要你管的（`PiShown.speaksOnTask`）旁边写状态词，点了打开会话；
/// 还没交出去的叶子是一个"▶"，点了把任务的正文交给 Agent（Mac 直接交出，手机浮起发给 Agent 的输入框带着它）。
/// Mac 上指针停在这一行时（`rowHovered`）"▶ 开始"以靛青露出来、状态标旁写出状态词；没停时"开始"不画（签名色只给焦点，ui.md）。
struct TaskNextMark: View {
    let next: TaskNext
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
                PiStateDot(shown: shown, size: Self.dot).relaySpot(session: session.sessionID, row: .task)
                if shown.speaksOnTask || lit { Text(shown.label).foregroundStyle(shown.labelTint(palette)) }
            case .start:
                Image(.start).font(Self.glyph)
                #if os(macOS)
                Text("开始").fontWeight(.semibold)
                #endif
            }
        }
        .font(TaskMetrics.caption)
        // 没亮起的"▶"与待办的圈同一个淡墨：它是这一行可以做的事，不是要你看的事
        .foregroundStyle(starts ? (lit ? palette.signature : palette.ink3) : palette.ink2)
        .lineLimit(1).fixedSize()
        // 点按区比图形宽；图形贴着行的那一边（手机行尾的一列右缘对齐，紧跟标题时靠左），不在点按区里居中
        .frame(minWidth: Self.target, minHeight: Self.target, alignment: edge)
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

extension PiShown {
    /// 任务行上要写出状态词的：要你动手的（`needsYou`），加上停在半路（被打断）与做完一轮你还没看的。在跑的只有会动的线。
    var speaksOnTask: Bool { needsYou || status == .interrupted || status == .unread }
}

extension TaskNext {
    /// 行上写出了状态词（`PiShown.speaksOnTask`）。
    var speaks: Bool { if case .agent(let shown, _) = self { shown.speaksOnTask } else { false } }
    /// 会话此刻在跑（圈上那一段走流光）。
    var isRunning: Bool { if case .agent(let shown, _) = self { shown.isRunning } else { false } }
}

extension Workspace {
    /// 一行的"下一步"：给了此刻干活的叶子（`lead`）看它，否则看这件自己。
    func next(for task: Card, lead: Card?, in agents: AgentLinks, steps: TaskProgress?) -> TaskNext? {
        lead.map { next(for: $0, in: agents, steps: nil) } ?? next(for: task, in: agents, steps: steps)
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
