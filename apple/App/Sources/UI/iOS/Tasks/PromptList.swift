#if os(iOS)
import CueStore
import CueText
import SwiftUI

/// 任务的提示词：一张一张卡（内容预览与发没发出去），点开是大编辑区，卡上就地"发给 Agent"；末尾"写一条提示词"新建并进入编辑。
/// 提示词是开会话时的第一句：任务绑了会话后话都在会话里说，末尾换成会话此刻的样子（`AgentStatusCard`，点了打开会话；挑来的灵感接进会话的回复框，见 `Workspace.attach`）。
/// 右上可从本项目的灵感里挑一条挂上来。
struct PromptList: View {
    let task: Card
    let detail: TaskDetail?
    let open: (Card) -> Void
    let hand: (Card) -> Void
    let write: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents

    var body: some View {
        let prompts = detail?.prompts ?? []
        let primary = detail?.primaryPrompt(agents: agents)
        let services = services
        VStack(alignment: .leading, spacing: TaskMetrics.cardGap) {
            // 绑了会话：这件事此刻的样子在最上面，提示词在它下面
            if let session = task.piSessionID {
                AgentStatusCard(sessionID: session, item: agents.items[task.id]).padding(.bottom, 10)
            }
            HStack(alignment: .firstTextBaseline) {
                // 绑了会话又没有提示词时不写空着的段标题，只留"从灵感里挑"
                if !prompts.isEmpty || task.piSessionID == nil {
                    Text("提示词").font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                }
                if !prompts.isEmpty {
                    Text("\(prompts.count)").monospacedDigit().font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                }
                Spacer()
                pick
            }
            ForEach(prompts) { prompt in
                PromptCard(
                    prompt: prompt, delivery: PromptDelivery(prompt.id, agents: agents, at: services.speech),
                    primary: prompt.id == primary, open: { open(prompt) },
                    hand: { hand(prompt) })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if task.piSessionID == nil, prompts.allSatisfy(\.isPinned) {  // 一个叶子最多一条草稿：已有就不再给"写一条"
                Button(action: write) {
                    Label("写一条提示词：要 Agent 做什么", systemImage: "plus")
                        .font(TaskMetrics.font.weight(.medium)).foregroundStyle(palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: TaskMetrics.rowHeight, alignment: .leading)
                        .padding(.horizontal, TaskMetrics.cardPadding)
                        .background(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous)
                            .strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle(.wide))
            }
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
        }
    }
}


/// 一条提示词：内容预览，下面一行左边写发没发出去（`PromptDelivery`：发送中、没送到的原因；没发的不写），右边是钮：
/// 没发的"发给 Agent"——第一条是靛青的（一页的焦点，见 `TaskDetail.primaryPrompt`），其余是墨色文字；没送到的"重发"。
/// 送达的提示词已经用掉（资料库里删了），不在这里；Agent 做到哪了只在任务那一行写。点卡打开大编辑区；长按是灵感的菜单。
struct PromptCard: View {
    let prompt: Card
    let delivery: PromptDelivery
    let primary: Bool
    let open: () -> Void
    let hand: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

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
                if delivery.canSend { handButton(enabled: !text.title.isEmpty || !text.images.isEmpty) }
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

    private func handButton(enabled: Bool) -> some View {
        let fresh = delivery == .unsent
        return Button(action: handOrResend) {
            Label(fresh ? "发给 Agent" : "重发", systemImage: primary ? "paperplane.fill" : "paperplane")
                .font(TaskMetrics.caption.weight(primary ? .semibold : .medium))
                .foregroundStyle(primary ? palette.signature : fresh ? palette.ink : palette.ink2)
                .padding(.horizontal, primary ? 12 : 4).frame(height: TaskMetrics.chipHeight)
                .background(primary ? palette.signature.opacity(0.12) : .clear, in: .capsule)
                // 点得到的范围上下各多出一截，但不撑高卡片：卡片底边只比这一排低一个内边距
                .contentShape(.rect.inset(by: -(TaskMetrics.chipTarget - TaskMetrics.chipHeight) / 2))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
    }

    /// 重发先撤回没送到的那条（撤不回——Mac 已领取——就不重发，提示原因），再打开发给 Agent。
    private func handOrResend() {
        guard case .failed(let request, _) = delivery else { return hand() }
        let services = workspace.services, hand = hand
        workspace.attempt {
            try await services.withdraw(.request(request))
            hand()
        }
    }

    @ViewBuilder private var status: some View {
        switch delivery {
        case .unsent:
            EmptyView()
        case .sending:
            HStack(spacing: 6) {
                Spinner(.mini)
                Text("发送中").foregroundStyle(palette.ink2)
            }
            .font(TaskMetrics.caption)
        case .failed(_, let failure):
            Text(failure.text(sync: workspace.services.syncStatus)).font(TaskMetrics.caption).foregroundStyle(palette.failure).lineLimit(2)
        }
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
                        if let shown { PiStateDot(shown: shown, size: 7) }
                        Text(look?.title ?? "打开会话").font(TaskMetrics.font.weight(.semibold)).foregroundStyle(palette.ink)
                    }
                    if let note = look?.note {
                        Text(note).font(TaskMetrics.caption).foregroundStyle(palette.ink2).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .padding(TaskMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.paperLit, in: .rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous).strokeBorder(palette.paperEdge()))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.wide))
        .accessibilityHint("打开会话")
    }
}
#endif
