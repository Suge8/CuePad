import CueStore
import CueText
import SwiftUI

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
    @Environment(\.cardAgents) private var agents

    var body: some View {
        let prompts = detail?.prompts ?? []
        let primary = detail?.primaryPrompt(agents: agents)
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
                    prompt: prompt, state: detail?.state(of: prompt, agents: agents) ?? .unsent, primary: prompt.id == primary, open: { open(prompt) }, hand: { hand(prompt) })
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
/// Agent 还在处理时是"看会话 ›"，做完、出错或结束后是墨色文字"再交一次"（`PromptState.action`）。点卡打开大编辑区；长按是灵感的菜单。
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
                switch state.action {
                case .handOff: handButton(fresh: true, enabled: !text.title.isEmpty || !text.images.isEmpty)
                case .handAgain: handButton(fresh: false, enabled: true)
                case .watch(let item): watch(item)
                case nil: EmptyView()
                }
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

    private func handButton(fresh: Bool, enabled: Bool) -> some View {
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
        .disabled(!enabled)
    }

    /// Agent 还在处理这条：右边只给"看会话 ›"。
    private func watch(_ item: PiSessionListItem) -> some View {
        sessionLink(item) {
            HStack(spacing: 3) {
                Text("看会话")
                Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
            }
            .font(TaskMetrics.caption.weight(.medium)).foregroundStyle(palette.ink2).padding(.horizontal, 4)
        }
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
                // Agent 回了这一条：带字的对话气泡。不用对勾——对勾只表示完成，提示词有了回答不等于任务做完
                line(name: item?.state.title, word: "已回复", tint: palette.ink) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(palette.ink)
                }
            }
        }
    }

    /// 交出去过的状态一律"状态标 会话名 · 状态词"，名字长了只截名字。
    private func line(name: String?, word: String, tint: Color, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 6) {
            mark().accessibilityHidden(true)
            if let name {
                Text(name).foregroundStyle(palette.ink2).lineLimit(1)
                Dot().foregroundStyle(palette.ink3)
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
