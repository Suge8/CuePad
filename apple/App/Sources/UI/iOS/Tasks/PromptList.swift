#if os(iOS)
import CueStore
import CueText
import SwiftUI

/// 任务的提示词：一张一张卡（内容预览与发没发出去），点开是大编辑区，卡上就地"发给 Agent"；末尾"写一条提示词"新建并进入编辑。
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
                if !prompts.isEmpty {
                    Text("\(prompts.count)").monospacedDigit().font(TaskMetrics.caption).foregroundStyle(palette.ink3)
                }
                Spacer()
                pick
            }
            ForEach(prompts) { prompt in
                PromptCard(
                    prompt: prompt, delivery: PromptDelivery(prompt.id, agents: agents), primary: prompt.id == primary, open: { open(prompt) },
                    hand: { hand(prompt) })
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
        }
    }
}


/// 一条提示词：内容预览，下面一行左边写发没发出去（`PromptDelivery`：发送中、没送到的原因、已发；没发的不写），右边是钮：
/// 没发的"发给 Agent"——第一条是靛青的（一页的焦点，见 `TaskDetail.primaryPrompt`），其余是墨色文字；没送到的"重发"。
/// 发出去的就是发出去了，不再给钮；Agent 做到哪了只在任务那一行写。点卡打开大编辑区；长按是灵感的菜单。
struct PromptCard: View {
    let prompt: Card
    let delivery: PromptDelivery
    let primary: Bool
    let open: () -> Void
    let hand: () -> Void
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
        return Button(action: hand) {
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
        case .failed(let reason):
            Text(reason).font(TaskMetrics.caption).foregroundStyle(palette.failure).lineLimit(2)
        case .sent:
            Text("已发").font(TaskMetrics.caption).foregroundStyle(palette.ink3)
        }
    }
}
#endif
