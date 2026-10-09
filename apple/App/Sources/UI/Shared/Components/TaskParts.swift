import CueStore
import CueText
import SwiftUI

// 任务页（手机浮窗、Mac 整页）的几块：任务是一件要做成的事——标题与一句说明（`TaskHeading`）；
// 要交给 Agent 的话是挂在它下面的提示词，一张一张卡（`PromptList`），是这一页的主体；子任务是次要的一组（`SubtaskList`）。

/// 一条任务的下级、各自做完没有、交给的会话：任务页一次读出，各块只画。
nonisolated struct TaskDetail: Sendable, Equatable {
    /// 提示词与子任务，同级手动顺序。
    var children: [Card]
    /// 下级各自做完没有（与 `children` 同序）：提示词已回复、子任务完成。完成圈按它分段。
    var marks: [ChildMark]
    /// 提示词交给的会话（含手机发出还没执行的、正在开的新会话）。
    var agents: AgentLinks
    /// 能挑来作提示词的：本项目散放的灵感，最近改过的在前。
    var ideas: [Card]

    static let tables: Set<StoreTable> = [.cards, .piSessionStates, .deliveryRequests, .sendRecords]

    static let ideaLimit = 20

    static func read(_ id: UUID, from store: isolated CueStore) throws -> TaskDetail {
        let task = try store.card(id)
        let ideas = try store.cards(in: task?.projectID).filter { !$0.isTask && !$0.isPinned }.sorted { $0.modifiedAt > $1.modifiedAt }
        return TaskDetail(
            children: try store.children(of: id), marks: try store.childMarks(of: id)[id] ?? [],
            agents: try AgentLinks.read(from: store), ideas: Array(ideas.prefix(ideaLimit)))
    }

    var prompts: [Card] { children.filter { !$0.isTask } }
    var subtasks: [Card] { children.filter(\.isTask) }

    /// 一页的焦点：第一条还没交出去的提示词，只有它的"交给 Agent"是靛青主钮，其余没发的退成墨色，一眼看出从哪条开始。
    var primaryPrompt: UUID? { prompts.first { state(of: $0) == .unsent }?.id }

    func state(of prompt: Card) -> PromptState {
        let replied = zip(children, marks).first { $0.0.id == prompt.id }?.1.isDone ?? false
        return PromptState(isReplied: replied, handoff: agents.items[prompt.id], launching: agents.launching.contains(prompt.id))
    }
}

/// 任务的标题（单行）与可选的一句说明，就地改、自动保存（存成两行，见 `CueTask`）。标题里按回车跳到说明。
struct TaskHeading: View {
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var note = ""
    @State private var autosave: Autosave?
    @FocusState private var focus: Field?
    private enum Field { case title, note }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("这件事是…", text: $title, axis: .vertical)
                .font(TaskMetrics.title).foregroundStyle(task.status == .done ? palette.ink3 : palette.ink)
                .lineLimit(1...3).focused($focus, equals: .title)
                .onChange(of: title) { _, next in
                    // 标题只有一行：回车去写说明
                    if next.contains("\n") { title = next.replacingOccurrences(of: "\n", with: ""); focus = .note }
                    save()
                }
            TextField("加一句说明（可不填）", text: $note, axis: .vertical)
                .font(TaskMetrics.font).foregroundStyle(palette.ink2)
                .lineLimit(1...3).focused($focus, equals: .note)
                .onChange(of: note) { save() }
        }
        .textFieldStyle(.plain)
        .onAppear {
            let text = CueTask(task.body)
            title = text.title
            note = text.note
            let store = services.store, id = task.id
            autosave = Autosave(save: { body in try await store.updateCard(id) { $0.body = body } }, onError: workspace.fail)
        }
        .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    private func save() {
        let stored = CueTask(title: title, note: note).stored
        guard stored != CueTask(task.body).stored else { return }
        autosave?.changed(stored)
    }
}

/// 任务的提示词：一张一张卡（内容预览与此刻怎样），点开是大编辑区，卡上就地"交给 Agent"；末尾"写一条提示词"新建并进入编辑。
/// 右上可从本项目的灵感里挑一条挂上来。
struct PromptList: View {
    let task: Card
    let detail: TaskDetail?
    let open: (Card) -> Void
    let hand: (Card) -> Void
    let write: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let prompts = detail?.prompts ?? []
        VStack(alignment: .leading, spacing: TaskMetrics.cardGap) {
            HStack(alignment: .firstTextBaseline) {
                Text("提示词").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                if let heading = PromptTally(detail?.marks).heading {
                    Text(heading).monospacedDigit().font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                }
                Spacer()
                pick
            }
            ForEach(prompts) { prompt in
                PromptCard(
                    prompt: prompt, state: detail?.state(of: prompt) ?? .unsent, primary: prompt.id == detail?.primaryPrompt, open: { open(prompt) }, hand: { hand(prompt) })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Button(action: write) {
                Label(prompts.isEmpty ? "写一条提示词：要 Agent 做什么" : "写一条提示词", systemImage: "plus")
                    .font(TaskMetrics.font.weight(.medium)).foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading)
                    .padding(.horizontal, TaskMetrics.cardPadding)
                    .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous)
                        .strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(.rect)
            }
            .buttonStyle(PressStyle(scale: 0.98))
        }
        .animation(Motion.quick, value: prompts.map(\.id))
    }

    /// 从本项目的灵感里挑一条挂上来；没有可挑的不出现。
    @ViewBuilder private var pick: some View {
        let ideas = detail?.ideas ?? []
        if !ideas.isEmpty {
            Menu {
                ForEach(ideas) { idea in
                    Button(idea.title) {
                        let id = idea.id, task = task.id
                        workspace.attempt { try await workspace.attach(id, to: task) }
                    }
                }
            } label: {
                Label("从灵感里挑", systemImage: "tray.and.arrow.down").font(TaskMetrics.caption).foregroundStyle(palette.ink2)
                    .frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            #endif
        }
    }
}

/// 一条提示词：内容预览，下面一行是交给 Agent 的钮，交出去过的左边写它此刻怎样（"会话名 · 思考中 / 已结束 / 已回复"，点它看会话）：
/// 第一条还没发的是靛青的"交给 Agent"（一页的焦点，不另写"未发"，见 `TaskDetail.primaryPrompt`），其余没发的是墨色文字"交给 Agent"，
/// 交出去过的是墨色文字"再交一次"。点卡打开大编辑区；长按是灵感的菜单。
struct PromptCard: View {
    let prompt: Card
    let state: PromptState
    let primary: Bool
    let open: () -> Void
    let hand: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        let text = CardText(prompt.body)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text.label)
                    .font(TaskMetrics.font.weight(.medium)).foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                if !text.preview.isEmpty {
                    Text(text.preview).font(TaskMetrics.caption).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                status
                Spacer(minLength: 8)
                let fresh = state == .unsent
                Button(action: hand) {
                    Label(fresh ? "交给 Agent" : "再交一次", systemImage: primary ? "paperplane.fill" : "paperplane")
                        .font(TaskMetrics.caption.weight(primary ? .semibold : .medium))
                        .foregroundStyle(primary ? palette.signature : fresh ? palette.ink : palette.ink2)
                        .padding(.horizontal, primary ? 12 : 4).frame(height: TaskMetrics.chipHeight)
                        .background(primary ? palette.signature.opacity(0.12) : .clear, in: .capsule)
                        // 点得到的范围上下各多出一截，但不撑高卡片：卡片底边只比这一排低一个内边距
                        .contentShape(.rect.inset(by: -(TaskMetrics.chipTarget - TaskMetrics.chipHeight) / 2))
                }
                .buttonStyle(PressStyle())
                .disabled(text.title.isEmpty && text.images.isEmpty)
            }
        }
        .padding(TaskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 与这一页同一种纸：略亮的纸面加一圈细线，不用灰底压重
        .background(palette.paperLit, in: .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous).strokeBorder(palette.paperEdge()))
        .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius))
        .onTapGesture(perform: open)
        .contextMenu { CardActions(card: prompt) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "打开", open)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .unsent:
            EmptyView()
        case .launching:
            HStack(spacing: 6) {
                Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 8, height: 8)
                Text("正在开会话").foregroundStyle(palette.ink2)
            }
            .font(TaskMetrics.caption)
        case .working(let item):
            let shown = services.settings.shown(item)
            sessionLink(item) {
                line(name: item.state.title, word: shown.label, tint: shown.labelTint(palette)) { PiStateDot(shown: shown, size: 7) }
            }
        case .ended(let item):
            sessionLink(item) {
                line(name: item.state.title, word: "已结束", tint: palette.ink3) { Image(systemName: "stop.circle").foregroundStyle(palette.ink3) }
            }
        case .replied(let item):
            sessionLink(item) {
                line(name: item?.state.title, word: "已回复", tint: palette.ink) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.ink)
                }
            }
        }
    }

    /// 交出去过的状态一律"状态标 会话名 · 状态词"，名字长了只截名字。
    private func line(name: String?, word: String, tint: Color, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 6) {
            mark()
            if let name {
                Text(name).foregroundStyle(palette.ink2).lineLimit(1)
                Text("·").foregroundStyle(palette.ink3)
            }
            Text(word).foregroundStyle(tint).lineLimit(1).fixedSize()
        }
    }

    /// 点状态看那个会话。
    @ViewBuilder private func sessionLink(_ item: PiSessionListItem?, @ViewBuilder label: () -> some View) -> some View {
        let content = label().font(TaskMetrics.caption).frame(minHeight: TaskMetrics.chipTarget).contentShape(.rect)
        if let item {
            #if os(iOS)
            Button { navigation.openSession(item.state.id, sessionID: item.state.sessionID, store: services.store) } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint("看 Agent 的会话")
            #else
            content.sessionLink(item.state.sessionID).help("交给了 Agent 会话「\(item.state.title)」，点开看")
            #endif
        } else {
            content
        }
    }
}

/// 子任务：在提示词之后的次要一组，可勾的圈与标题（点标题打开）；没有子任务时整组不出现。
/// 子任务不在这里加：在任务大纲里把任务拖到它上面就成了它的子任务。
struct SubtaskList: View {
    let detail: TaskDetail?
    let open: (Card) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let subtasks = detail?.subtasks ?? []
        if !subtasks.isEmpty { list(subtasks) }
    }

    private func list(_ subtasks: [Card]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("子任务").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                if let progress = TaskProgress.subtasks(in: detail?.marks) {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                }
            }
            ForEach(subtasks) { row($0) }
        }
        .font(TaskMetrics.font)
        .animation(Motion.quick, value: subtasks.map(\.id))
    }

    private func row(_ child: Card) -> some View {
        HStack(spacing: 8) {
            Button {
                workspace.attempt { try await workspace.toggle(child) }
            } label: {
                TaskRingView(status: child.status, ring: .plain, done: child.status == .done, size: TaskMetrics.icon * 0.72)
                    .frame(width: TaskMetrics.icon, height: TaskMetrics.rowHeight).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TaskSpeech.toggle(done: child.status == .done))
            Button { open(child) } label: {
                Text(child.title)
                    .strikethrough(child.status == .done)
                    .foregroundStyle(child.status == .done ? palette.ink3 : palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .sensoryFeedback(.success, trigger: child.status) { $1 == .done }
    }
}

/// 任务页标题左边的完成圈：点它完成（完成的回到待办）；还有没完成的子任务时先问一句，确认后一起完成。
struct TaskRingButton: View {
    let task: Card
    let marks: [ChildMark]?
    var size: CGFloat = TaskMetrics.titleRing
    @Environment(Workspace.self) private var workspace
    @State private var confirming = false

    var body: some View {
        Button {
            if task.status != .done, TaskCopy.hasOpen(.subtasks(in: marks)) { confirming = true } else { toggle() }
        } label: {
            TaskRingView(status: task.status, ring: TaskRing(marks), done: task.status == .done, size: size)
                .frame(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: task.status) { $1 == .done }
        .accessibilityLabel(TaskSpeech.toggle(done: task.status == .done))
        .accessibilityValue([TaskSpeech.value(task.status), TaskRing(marks).speech].compactMap { $0 }.joined(separator: "，"))
        .confirmationDialog(TaskCopy.openSubtasks(.subtasks(in: marks)), isPresented: $confirming, titleVisibility: .visible) {
            Button("全部完成", action: toggle)
        }
    }

    private func toggle() {
        let task = task
        workspace.attempt { try await workspace.toggle(task) }
    }
}

/// 任务行尾的"完成"：提示词都已回复、任务还没完成时出现，点了才完成（任务不自动完成）。行上已写着"全部已回复"，钮只写动作。
struct MarkDoneChip: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Text("完成")
                .font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink)
                .padding(.horizontal, 10).frame(height: TaskMetrics.chipHeight)
                .overlay(Capsule().strokeBorder(palette.hair))
                .frame(minHeight: TaskMetrics.chipTarget).contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityHint("提示词都已回复")
    }
}

/// 任务区各块的尺寸（手机按动态字体与 44pt 点按，Mac 用小字）。
enum TaskMetrics {
    #if os(iOS)
    static let font = Font.subheadline
    static let icon: CGFloat = 28
    static let rowHeight: CGFloat = 44
    static let caption = Font.footnote
    static let chipHeight: CGFloat = 30
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    static let title = Typography.heading
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let cardGap: CGFloat = 10
    #else
    static let font = Typography.body
    static let icon: CGFloat = 17
    static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipHeight: CGFloat = 24
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    static let title = Typography.heading
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let cardGap: CGFloat = 8
    #endif
}

/// 任务的完成圈（`TaskRing`），全 App 的任务只有这一种图形（行、任务页、书架"正在推进"、挂到任务面板、Mac 面板）：
/// 完成是对勾；没完成的是一个实线圈，进行中左半填满，待办空心——这个形状只随状态变，
/// 有没有下级、下级做了多少都不换掉它。有下级时进度另铺在右半：从 12 点顺时针往 6 点填一层淡色，做完多少填多少，
/// 全做完是右半整个淡色（任务还要你自己勾：不画成实心，与完成的对勾分开）。
/// 不用"淡圈上描一道弧"：小尺寸下那就是系统的加载转圈。扇形的变化有短过渡。
struct TaskRingView: View {
    let status: TaskStatus?
    let ring: TaskRing
    /// 界面上已经显示完成（勾了还没写入时也算）。
    let done: Bool
    let size: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let faint = 0.35

    var body: some View {
        Group {
            if done || status == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(TaskGlyph.tint(.done, palette))
                    .transition(.opacity)
            } else {
                open
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
        .animation(Motion.spatial(Motion.quick, reduceMotion: reduceMotion), value: ring)
        .animation(Motion.quick, value: done)
        .accessibilityHidden(true)
    }

    /// 与 SF 的 circle 同尺寸同线宽的实线圈（颜色照状态）；圈里与圈线留一线缝，半圆与扇形的边才读得出来。
    private var open: some View {
        let tint = TaskGlyph.tint(status, palette), line = max(1.4, size * 0.095)
        return ZStack {
            Circle().stroke(tint, lineWidth: line)
            ZStack {
                if case .progress(let finished, let total) = ring {
                    // 右半：12 点顺时针到 6 点按比例
                    Sector(fraction: Double(finished) / Double(max(total, 1)) / 2).fill(tint.opacity(Self.faint))
                }
                if status == .inProgress { Circle().trim(from: 0.25, to: 0.75).fill(tint) }
            }
            .padding(line * 1.1)
        }
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size * 1.02, height: size * 1.02)
    }
}

/// 从 12 点顺时针的扇形，`fraction` 0…1；可动画（任务完成圈与上下文圆环共用，同一种饼图画法）。
nonisolated struct Sector: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fraction > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY), start = Angle.degrees(-90)
        var path = Path()
        path.move(to: center)
        // 视图坐标 y 朝下：clockwise: false 在屏幕上是顺时针
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: start, endAngle: start + .degrees(360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 任务圆圈的颜色（形状只在 `TaskRingView`）：待办淡墨、进行中与完成墨色。
/// 进行中不用签名色：在动的状态靠形状区分，签名色只给一屏的焦点。
enum TaskGlyph {
    static func tint(_ status: TaskStatus?, _ palette: Palette) -> Color {
        switch status {
        case .done, .inProgress: palette.ink
        case .todo, nil: palette.ink3
        }
    }
}
