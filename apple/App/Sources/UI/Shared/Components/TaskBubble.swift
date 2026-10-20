import CueEditor
import CueStore
import CueText
import SwiftUI

/// 任务气泡：点一条任务（项目页与任务页的行、Cue 对话里提到的任务、⌘K、归档、小组件链接），从点的那一下长出来的一张纸
/// （\`BubbleFrame\`，Mac 与手机同一个视图，只差字号与行高）。不换页、不压暗；点外面或 Esc 关，点外面另一条就换成它的气泡。
/// 上面是这件事：完成圈、标题（就地改）、"⋯"，一行所在项目与"步骤 n/m"，下面是它的正文（标题下面要交代给 Agent 的话，点了就地写）；
/// 有步骤时列出步骤（同全 App 的任务行 \`TaskLine\`），点一步气泡原地翻到这一步、左上出返回；顶层任务末尾一行添加步骤。
/// 最下面一条是"下一步"：交给了会话是它此刻的样子（吉祥物、一句话），点了去会话；还没开始的叶子是"开始"（正文连同标题交给 Agent）；
/// 有步骤的看最该你看的那一步（\`Workspace.lead\`）。
struct TaskBubble: View {
    /// 一次打开：\`id\` 每次打开都不同（同一件事再点一次也从新的那一下长出来）；\`step\` 是翻到的步骤，翻页不换 \`id\`。
    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// 顶层任务。
        let task: UUID
        /// 翻到的步骤；nil 是这件事本身（有步骤时是步骤一览）。
        var step: UUID?
        /// 从哪长出来（窗口坐标）；nil 是没有落点（\`Workspace.openTask\`）。
        let anchor: CGPoint?
    }

    let request: Request
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @State private var data: BubbleData?
    /// 正文正在写（点了正文之后才建编辑器：打开气泡不建它）。"开始"先等它落盘再交出去。
    @State private var editing: CardEditing?

    var body: some View {
        // ZStack 而不是 Group：数据读到之前 Group 里没有视图，挂在它上面的读库也就不会开始
        ZStack {
            if let data {
                let focus = data.focus(step)
                BubblePage(data: data, focus: focus, editing: $editing)
                    .id(focus.id)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: step)
        #if os(macOS)
        // Mac 的浮层挂在页面之外：步骤的状态点、"下一步"读的"交给了哪个会话"在这里补上
        .modifier(WindowCardAgents(workspace: workspace))
        #endif
        .observing(services.store, id: request.task, into: $data, onError: workspace.fail) { [task = request.task] in try BubbleData.read(task, from: $0) }
        // 别处删掉、归档了它，或改回了灵感：气泡收起
        .onChange(of: data?.gone) { if data?.gone == true { close() } }
        // 翻页、关气泡都先写下正文里没保存的字
        .onChange(of: step) { leaveEditing() }
        .onDisappear(perform: leaveEditing)
    }

    /// 翻到的那一步：开着的这一次以工作区里的为准（翻页只改它，不换这一次）。
    private var step: UUID? { workspace.openTask?.id == request.id ? workspace.openTask?.step : request.step }

    private func leaveEditing() {
        editing?.leave()
        editing = nil
    }
}

/// 气泡里的一页：这件事本身，或翻到的一步。
private struct BubblePage: View {
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

    /// 所在项目与做到第几步。
    private var meta: some View {
        HStack(spacing: 5) {
            ProjectGlyph(project: data.project, size: BubbleMetrics.glyph)
            Text(data.project?.name ?? "").lineLimit(1)
            if let progress = data.progress {
                Dot()
                Text(TaskCopy.progress(progress)).monospacedDigit()
            }
        }
        .font(BubbleMetrics.meta).foregroundStyle(palette.ink3)
        .padding(.leading, BubbleMetrics.indent).padding(.top, 3)
        .accessibilityElement(children: .combine)
    }

    private var more: some View {
        Menu { CardActions(card: focus, more: true) } label: {
            Image(.more).font(BubbleMetrics.meta.weight(.bold)).foregroundStyle(palette.ink2)
                .frame(width: BubbleMetrics.moreTarget, height: BubbleMetrics.moreTarget).contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
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
            .buttonStyle(.plain)
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

/// 气泡最下面"下一步"那一条。
private struct BubbleFooter: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    var body: some View {
        if focus.id == data.goal.id, !data.steps.isEmpty {
            switch workspace.lead(of: data.steps, in: agents) {
            case .agent(_, let session)?:
                if let step = data.steps.first(where: { $0.piSessionID == session.sessionID }) { AgentStrip(leaf: step, caption: step.title) }
            case .start(let leaf)?: StartBar(leaf: leaf, caption: leaf.title, editing: nil)
            case nil: EmptyView()
            }
        } else if agents.items[focus.id] != nil {
            AgentStrip(leaf: focus, caption: nil)
        } else if focus.status != .done, !agents.launching.contains(focus.id) {
            StartBar(leaf: focus, caption: nil, editing: editing)
        }
    }
}

/// 交给了会话的叶子此刻怎样（\`TaskAgentLook\`，两端同一份说法）：吉祥物（在做时轻轻浮动）、状态标与一句标题、一句进展；整条点了去会话。
private struct AgentStrip: View {
    let leaf: Card
    /// 有步骤的任务看的是哪一步（写在进展前面）。
    let caption: String?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        if let item = agents.items[leaf.id] {
            #if os(macOS)
            let state = workspace.withLiveState(item.state)
            #else
            let state = item.state
            #endif
            let shown = workspace.shown(state, delivery: item.delivery)
            let look = TaskAgentLook(shown, line: PiProgress.note(of: state, failure: shown.undelivered?.text(sync: workspace.services.syncStatus)))
            Button { open(shown, state) } label: { strip(look, shown: shown, session: state.sessionID) }
                .buttonStyle(PressStyle(.wide))
                .accessibilityElement(children: .combine)
                .accessibilityHint("打开会话")
        }
    }

    private func strip(_ look: TaskAgentLook, shown: PiShown, session: String) -> some View {
        HStack(spacing: BubbleMetrics.gap) {
            MascotFace(mascot: look.mascot, floats: look.floats && !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    PiStateDot(shown: shown, size: BubbleMetrics.dot).relaySpot(session: session, row: .task)
                    Text(look.title).font(BubbleMetrics.strong).foregroundStyle(palette.ink).lineLimit(1)
                }
                if let line = Dotted(caption, look.note).nonEmpty {
                    Text(line).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text("去会话").font(BubbleMetrics.meta.weight(.semibold))
                .foregroundStyle(shown.needsYou ? palette.onFill : palette.ink)
                .padding(.horizontal, 14).frame(height: BubbleMetrics.capsule)
                .background(shown.needsYou ? palette.signatureFill : palette.fill, in: .capsule)
        }
        .padding(BubbleMetrics.stripPadding)
        .background(palette.fill, in: .rect(cornerRadius: BubbleMetrics.stripRadius, style: .continuous))
        .contentShape(.rect)
    }

    private func open(_ shown: PiShown, _ session: PiSessionState) {
        #if os(macOS)
        workspace.show(.session(session.sessionID))
        #else
        close()
        navigation.follow(.agent(shown, session: session), store: services.store)
        #endif
    }
}

/// 还没交出去的叶子："开始"——正文连同标题作为第一句交给 Agent（先写下正文里没保存的字）。Mac 左边另有"绑定会话"。
private struct StartBar: View {
    let leaf: Card
    /// 有步骤的任务开的是哪一步。
    let caption: String?
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        HStack(spacing: BubbleMetrics.gap) {
            #if os(macOS)
            if caption == nil {
                Menu { SessionBindItems(leaf: leaf) } label: {
                    Text("绑定会话").font(BubbleMetrics.meta).foregroundStyle(palette.ink3)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            #endif
            if let caption { Text(caption).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(1) }
            Spacer(minLength: 0)
            Button(action: start) {
                Label(caption == nil ? "开始" : "开始这一步", icon: .start)
                    .font(BubbleMetrics.meta.weight(.semibold)).foregroundStyle(palette.onFill)
                    .padding(.horizontal, 16).frame(height: BubbleMetrics.capsule)
                    .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint("把任务的正文交给 Agent，开始做")
        }
    }

    private func start() {
        let workspace = workspace, editing = editing, leaf = leaf
        #if os(iOS)
        let navigation = navigation
        close()
        #endif
        Task {
            do {
                let card = try await editing?.flushed() ?? leaf
                #if os(macOS)
                workspace.handOff(card)
                #else
                navigation.handToAgent(card)
                #endif
            } catch {
                workspace.fail(error)
            }
        }
    }
}

/// 吉祥物的小像：透明底的图；在做时轻轻上下浮动（Core Animation，\`LoopLayer.float\`）。
private struct MascotFace: View {
    let mascot: Mascot
    let floats: Bool

    var body: some View {
        Group {
            if floats, let image = mascot.bitmap(side: BubbleMetrics.mascot) {
                LoopLayer(kind: .float(image, lift: BubbleMetrics.mascot * 0.06), color: .clear)
            } else {
                Image(mascot.rawValue).resizable().scaledToFit()
            }
        }
        .frame(width: BubbleMetrics.mascot, height: BubbleMetrics.mascot)
        .accessibilityHidden(true)
    }
}

extension Workspace {
    /// 有步骤的任务此刻最该看的那一步的"下一步"：要你动手的会话优先，其次第一个有动静的会话，再次第一个能开始的步骤。
    func lead(of steps: [Card], in agents: AgentLinks) -> TaskNext? {
        let nexts = steps.compactMap { next(for: $0, in: agents, steps: nil) }
        func needsYou(_ next: TaskNext) -> Bool { if case .agent(let shown, _) = next { shown.needsYou } else { false } }
        func agent(_ next: TaskNext) -> Bool { if case .agent = next { true } else { false } }
        return nexts.first(where: needsYou) ?? nexts.first(where: agent) ?? nexts.first
    }
}

/// 气泡一次读出的东西：顶层任务、所在项目、它的步骤。
nonisolated struct BubbleData: Sendable, Equatable {
    var goal: Card
    var project: Project?
    var steps: [Card]
    /// 步骤完成了几个（\`CueStore.subtaskProgress\`）；没有步骤为 nil。
    var progress: TaskProgress?
    /// 已不是一条看得见的任务（删了、归档了、改回了灵感）。
    var gone: Bool { goal.deletedAt != nil || goal.archivedAt != nil || !goal.isTask }

    /// 翻到的那一页：那一步（还在时），否则这件事本身。
    func focus(_ step: UUID?) -> Card { steps.first { $0.id == step } ?? goal }

    static func read(_ id: UUID, from store: isolated CueStore) throws -> BubbleData {
        guard let goal = try store.card(id) else { throw CueStoreError.notFound }
        return BubbleData(
            goal: goal, project: try store.project(goal.projectID), steps: try store.children(of: id).filter(\.isTask),
            progress: try store.subtaskProgress(of: [id])[id])
    }
}

/// 气泡里的字号、间距与尺寸：Mac 按指针，手机按手指（行高 44）。
private enum BubbleMetrics {
    #if os(macOS)
    static let title = Font.system(size: 17, weight: .semibold)
    static let body = Typography.body
    static let strong = Typography.secondary.weight(.semibold)
    static let meta = Typography.meta
    static let padding = EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 16)
    static let gap: CGFloat = 10
    static let ringNudge: CGFloat = 1
    static let ringBleed: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.titleRing) / 2
    /// 标题、项目行、正文与步骤的圈都对齐到标题的字起点。
    static let indent: CGFloat = TaskMetrics.chipTarget - ringBleed + gap
    /// 步骤行的圈在它那一列（`TaskMetrics.ringColumn`）里居中：行往左挪半列空白，圈对着标题的字起点。
    static let rowLead: CGFloat = (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    static let section: CGFloat = 10
    static let lineSpacing: CGFloat = Typography.lineSpacing
    static let previewLines = 6
    static let editorHeight: CGFloat = 120
    static let editorInset: CGFloat = 6
    static let editorRadius: CGFloat = 10
    static let glyph: CGFloat = 11
    static let moreTarget: CGFloat = 26
    static let backHeight: CGFloat = 22
    static let dot: CGFloat = 6
    static let mascot: CGFloat = 34
    static let capsule: CGFloat = 28
    static let stripPadding = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    static let stripRadius: CGFloat = 12
    #else
    static let title = Font.title3.weight(.semibold)
    static let body = Font.body
    static let strong = Font.subheadline.weight(.semibold)
    static let meta = Font.footnote
    static let padding = EdgeInsets(top: 20, leading: 18, bottom: 16, trailing: 16)
    static let gap: CGFloat = 8
    static let ringNudge: CGFloat = -10
    static let ringBleed: CGFloat = (TaskMetrics.chipTarget - TaskMetrics.titleRing) / 2
    static let indent: CGFloat = TaskMetrics.chipTarget - ringBleed + gap
    static let rowLead: CGFloat = (TaskMetrics.ringColumn - TaskMetrics.stepRing) / 2
    static let section: CGFloat = 8
    static let lineSpacing: CGFloat = 3
    static let previewLines = 6
    static let editorHeight: CGFloat = 150
    static let editorInset: CGFloat = 10
    static let editorRadius: CGFloat = 14
    static let glyph: CGFloat = 12
    static let moreTarget: CGFloat = 44
    static let backHeight: CGFloat = 36
    static let dot: CGFloat = 7
    static let mascot: CGFloat = 40
    static let capsule: CGFloat = 36
    static let stripPadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    static let stripRadius: CGFloat = 18
    #endif
}
