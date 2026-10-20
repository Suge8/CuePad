#if os(iOS)
import CueStore
import CueText
import SwiftUI

/// 任务页（推入的整页纸，同灵感的纸页）：悬浮顶栏中间写它在哪个项目，右边"⋯"；内容最上面是完成圈与任务的标题（`TaskHeading`），
/// 下面是它的正文（标题下面要交代给 Agent 的话，长了折叠，点了弹出正文的纸页编辑）；叶子（没有步骤的任务）接着是"开始"——
/// 正文连同标题作为第一句交给 Agent（浮起发给 Agent 的输入框），绑了会话后换成会话此刻的样子（点了打开会话）。
/// 再往下是挂在它下面的资料与步骤（`SubtaskList`），都推进同一个导航栈。
struct TaskPage: View {
    let card: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @State private var detail: TaskDetail?
    @State private var editingBrief = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 完成圈的点按区比图形大，往左伸进页边距，图形仍与下面的内容对齐
                HStack(alignment: .top, spacing: 4) {
                    GoalCheck(task: card, subtasks: detail?.progress).offset(y: -8)
                    TaskHeading(task: card).padding(.top, 2)
                }
                .padding(.leading, -8)
                TaskBrief(task: card) { editingBrief = true }
                if detail?.subtasks.isEmpty != false { agentPart }
                references
                SubtaskList(detail: detail, open: { navigation.push(.card($0.id)) })
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader(workspace.catalog?.project(card.projectID)?.name ?? "") { more }
        .observing(services.store, id: card.id, into: $detail, onError: workspace.fail) { [id = card.id] in
            try TaskDetail.read(id, from: $0)
        }
        .sheet(isPresented: $editingBrief) {
            NavigationStack {
                CardEditorScreen(cardID: card.id, part: .rest)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成", icon: .save) { editingBrief = false } } }
            }
            .presentationBackground(palette.paper)
        }
        .onAppear { if DebugHooks.preset.briefOpen { editingBrief = true } }
    }

    /// 叶子交给 Agent 的那一块：还没交出去是"开始"，绑了会话是会话此刻的样子。
    @ViewBuilder private var agentPart: some View {
        if let session = card.piSessionID {
            AgentStatusCard(sessionID: session, item: agents.items[card.id])
        } else if case .start(let leaf) = workspace.next(for: card, in: agents, steps: nil) {
            Button { navigation.handToAgent(leaf) } label: {
                Label("开始", icon: .start)
                    .font(TaskMetrics.font.weight(.semibold)).foregroundStyle(palette.onFill)
                    .padding(.horizontal, 22).frame(height: TaskMetrics.rowHeight)
                    .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint("把任务的正文交给 Agent，开始做")
        }
    }

    /// 挂在这件事下面的资料（灵感）：标题一行，点了打开它。
    @ViewBuilder private var references: some View {
        let cards = detail?.references ?? []
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("资料").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                ForEach(cards) { idea in
                    Button { navigation.push(.card(idea.id)) } label: {
                        Text(idea.title).font(TaskMetrics.font).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { CardActions(card: idea) }
                }
            }
        }
    }

    private var more: some View {
        Menu { CardActions(card: card, more: true) } label: { Image(.more) }
            .accessibilityLabel("更多")
    }
}

/// 任务的正文：标题下面要交代给 Agent 的话，预览几行（长了折叠），点了编辑；还没写时是一行虚线框的提示。
private struct TaskBrief: View {
    let task: Card
    let edit: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: edit) {
            Group {
                if let rest = task.rest {
                    Text(CueFormat.plainText(rest)).font(TaskMetrics.font).foregroundStyle(palette.ink2).lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("写正文：要 Agent 做什么", icon: .add)
                        .font(TaskMetrics.font.weight(.medium)).foregroundStyle(palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading)
                        .padding(.horizontal, TaskMetrics.cardPadding)
                        .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous)
                            .strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.wide))
        .accessibilityLabel(task.rest.map { "正文，\(CueFormat.plainText($0))" } ?? "写正文")
        .accessibilityHint("编辑正文")
    }
}

/// 任务绑着的会话此刻怎样（与 Mac 任务浮窗同一份说法，`TaskAgentLook`）：吉祥物、一句标题、一句进展，点了打开会话。
/// 会话记录还没同步到时只写"打开会话"。
private struct AgentStatusCard: View {
    let sessionID: String
    let item: PiSessionListItem?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = item.map(workspace.shown)
        let look = item.map { item in
            let shown = workspace.shown(item)
            return TaskAgentLook(shown, line: PiProgress.note(of: item.state, failure: shown.undelivered?.text(sync: services.syncStatus)))
        }
        Button {
            navigation.openSession(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID, store: services.store)
        } label: {
            HStack(spacing: 12) {
                Image(look?.mascot.rawValue ?? Mascot.welcome.rawValue).resizable().scaledToFit().frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let shown { PiStateDot(shown: shown, size: 7).relaySpot(session: sessionID) }
                        Text(look?.title ?? "打开会话").font(TaskMetrics.font.weight(.semibold)).foregroundStyle(palette.ink)
                    }
                    if let note = look?.note {
                        Text(note).font(TaskMetrics.caption).foregroundStyle(palette.ink2).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(.forward).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .padding(TaskMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.paperLit, in: .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous).strokeBorder(palette.hair))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.wide))
        .accessibilityHint("打开会话")
    }
}
#endif
