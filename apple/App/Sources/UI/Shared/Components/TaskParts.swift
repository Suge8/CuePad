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
                if let text = PromptTally(detail?.marks).text { Text(text).font(TaskMetrics.caption).foregroundStyle(palette.ink3) }
                Spacer()
                pick
            }
            ForEach(prompts) { prompt in
                PromptCard(prompt: prompt, state: detail?.state(of: prompt) ?? .unsent, open: { open(prompt) }, hand: { hand(prompt) })
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

/// 一条提示词：内容预览，下面一行是它此刻怎样（未发 / 交给某会话·处理中 / 会话已结束 / 已回复，点它看会话）与"交给 Agent"。
/// 点卡打开大编辑区；长按是灵感的菜单。
struct PromptCard: View {
    let prompt: Card
    let state: PromptState
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
                Text(text.title.nonEmpty ?? (text.images.isEmpty ? "还没写" : "\(text.images.count) 张图"))
                    .font(TaskMetrics.font.weight(.medium)).foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                if !text.preview.isEmpty {
                    Text(text.preview).font(TaskMetrics.caption).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                status
                Spacer(minLength: 8)
                Button(action: hand) {
                    Label("交给 Agent", systemImage: "paperplane.fill")
                        .font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.signature)
                        .padding(.horizontal, 12).frame(height: TaskMetrics.chipHeight)
                        .background(palette.signature.opacity(0.12), in: .capsule)
                        .frame(minHeight: TaskMetrics.chipTarget).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .disabled(text.title.isEmpty && text.images.isEmpty)
            }
        }
        .padding(TaskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill, in: .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
        .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius))
        .onTapGesture(perform: open)
        .contextMenu { CardActions(card: prompt) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "打开", open)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .unsent:
            Label("未发", systemImage: "circle.dashed").foregroundStyle(palette.ink3).font(TaskMetrics.caption)
        case .launching:
            HStack(spacing: 6) {
                Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 8, height: 8)
                Text("正在开会话").foregroundStyle(palette.ink2)
            }
            .font(TaskMetrics.caption)
        case .working(let item):
            let shown = services.settings.shown(item)
            sessionLink(item) {
                HStack(spacing: 6) {
                    PiStateDot(shown: shown, size: 7)
                    Text(item.state.title).foregroundStyle(palette.ink2).lineLimit(1)
                    Text(shown.presence).foregroundStyle(shown.tint(palette)).lineLimit(1)
                }
            }
        case .ended(let item):
            sessionLink(item) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle").foregroundStyle(palette.ink3)
                    Text("会话已结束").foregroundStyle(palette.ink2)
                    Text(item.state.title).foregroundStyle(palette.ink3).lineLimit(1)
                }
            }
        case .replied(let item):
            sessionLink(item) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.ink)
                    Text("Agent 已回复").foregroundStyle(palette.ink)
                    if let item { Text(item.state.title).foregroundStyle(palette.ink3).lineLimit(1) }
                }
            }
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

/// 子任务：在提示词之后的次要一组，可勾的圈与标题（点标题打开），末尾一行就地加一个。
struct SubtaskList: View {
    let task: Card
    let detail: TaskDetail?
    let open: (Card) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var adding = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let subtasks = detail?.subtasks ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("子任务").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                if let progress = TaskProgress.subtasks(in: detail?.marks) {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                }
            }
            ForEach(subtasks) { row($0) }
            if adding {
                HStack(spacing: 8) {
                    Image(systemName: "circle").foregroundStyle(palette.ink3).frame(width: TaskMetrics.icon).accessibilityHidden(true)
                    TextField("子任务", text: $text).textFieldStyle(.plain).focused($focused).onSubmit(add)
                }
                .frame(minHeight: TaskMetrics.rowHeight)
                .onChange(of: focused) { if !focused, text.isEmpty { adding = false } }
            } else {
                Button {
                    adding = true
                    focused = true
                } label: {
                    Label("加一个子任务", systemImage: "plus").foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .font(TaskMetrics.font)
        .animation(Motion.quick, value: subtasks.map(\.id))
    }

    private func row(_ child: Card) -> some View {
        HStack(spacing: 8) {
            Button {
                workspace.attempt { try await workspace.toggle(child) }
            } label: {
                Image(systemName: TaskGlyph.symbol(child.status))
                    .foregroundStyle(TaskGlyph.tint(child.status, palette))
                    .contentTransition(.symbolEffect(.replace))
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

    /// ↩ 加一个并留在输入里，接着写下一个。
    private func add() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines), task = task
        guard !body.isEmpty else { return adding = false }
        text = ""
        focused = true
        workspace.perform { _ = try await $0.createTask(body, under: task.id) }
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

/// 任务行上的轻提示：提示词都已回复、任务还没完成时问一句"标记完成？"，点了才完成（任务不自动完成）。
struct MarkDoneChip: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Label("标记完成？", systemImage: "checkmark")
                .font(TaskMetrics.caption.weight(.medium)).foregroundStyle(palette.ink)
                .padding(.horizontal, 10).frame(height: TaskMetrics.chipHeight)
                .background(palette.fill, in: .capsule)
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
    static let title = Font.title3.weight(.semibold)
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let cardGap: CGFloat = 10
    #else
    static let font = Font.system(size: 13)
    static let icon: CGFloat = 16
    static let rowHeight: CGFloat = 26
    static let caption = Font.system(size: 11.5)
    static let chipHeight: CGFloat = 22
    static let chipTarget: CGFloat = 22
    static let titleRing: CGFloat = 18
    static let title = Font.system(size: 20, weight: .semibold)
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let cardGap: CGFloat = 8
    #endif
}

/// 任务的完成圈（`TaskRing`）：完成是对勾；没有下级是普通圆圈（进行中半满）；有下级时一段一段，做完的段满上墨色（颜色同 `TaskGlyph.tint`），
/// 太多时是一道按比例的弧；进行中在圈心点一个点。段的变化有短过渡。
struct TaskRingView: View {
    let status: TaskStatus?
    let ring: TaskRing
    /// 界面上已经显示完成（勾了还没写入时也算）。
    let done: Bool
    let size: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if done || ring == .plain {
                Image(systemName: done ? "checkmark.circle.fill" : TaskGlyph.symbol(status))
                    .font(.system(size: size))
                    .foregroundStyle(TaskGlyph.tint(done ? .done : status, palette))
                    .contentTransition(.symbolEffect(.replace))
            } else {
                arcs
                    .frame(width: size, height: size)
                    .overlay { if status == .inProgress { Circle().fill(TaskGlyph.tint(.inProgress, palette)).frame(width: size * 0.3) } }
                    .padding(size * 0.06)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
        .animation(Motion.spatial(Motion.quick, reduceMotion: reduceMotion), value: ring)
        .accessibilityHidden(true)
    }

    private var line: CGFloat { max(1.6, size * 0.13) }

    @ViewBuilder private var arcs: some View {
        switch ring {
        case .segments(let filled):
            // 段间留一点缝：一段时是整圈
            let count = filled.count, gap = count > 1 ? min(0.035, 0.3 / Double(count)) : 0
            ZStack {
                ForEach(filled.indices, id: \.self) { index in
                    let start = Double(index) / Double(count)
                    Circle()
                        .trim(from: start + gap / 2, to: start + 1 / Double(count) - gap / 2)
                        .stroke(filled[index] ? TaskGlyph.tint(.done, palette) : TaskGlyph.tint(.todo, palette).opacity(0.55), style: StrokeStyle(lineWidth: line, lineCap: .butt))
                }
            }
            .rotationEffect(.degrees(-90))
        case .fraction(let done, let total):
            ZStack {
                Circle().stroke(TaskGlyph.tint(.todo, palette).opacity(0.55), lineWidth: line)
                Circle().trim(from: 0, to: Double(done) / Double(max(total, 1)))
                    .stroke(TaskGlyph.tint(.done, palette), style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
            .rotationEffect(.degrees(-90))
        case .plain:
            EmptyView()
        }
    }
}

/// 任务的状态圆圈：待办淡墨空心、进行中朱砂半满、完成墨色对勾。
enum TaskGlyph {
    static func tint(_ status: TaskStatus?, _ palette: Palette) -> Color {
        switch status {
        case .done: palette.ink
        case .inProgress: palette.working
        case .todo, nil: palette.ink3
        }
    }

    static func symbol(_ status: TaskStatus?) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .todo, nil: "circle"
        }
    }
}
