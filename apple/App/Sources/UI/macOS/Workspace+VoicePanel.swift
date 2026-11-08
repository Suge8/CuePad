#if os(macOS)
import SwiftUI

/// 通话组件的宿主：开合与选择哪一件是呈现状态，业务动作全部回到 Workspace。
struct CueVoicePanel: View {
    /// 宿主给阅读与控制保留的高度；回复区超出其余空间时滚动查看。
    static let minimumHeight: CGFloat = 342
    let availableHeight: CGFloat
    @Environment(Workspace.self) private var workspace
    @State private var choosingExecution = false

    var body: some View {
        Group {
            if let presentation = workspace.voicePresentation {
                CueVoiceView(presentation: presentation, expanded: workspace.voiceExpanded,
                             availableHeight: availableHeight, action: act)
            }
        }
        .panel(isPresented: $choosingExecution) {
            VStack(alignment: .leading, spacing: Spacing.group) {
                Text("停止哪个会话？").font(Typography.title)
                ForEach(workspace.stoppableVoiceExecutions) { execution in
                    Button {
                        choosingExecution = false
                        stop(execution.state.sessionID)
                    } label: {
                        Text(verbatim: execution.task?.title ?? execution.state.title)
                    }
                    .buttonStyle(ControlButtonStyle(kind: .quiet))
                }
            }
            .padding(Spacing.panel)
        }
    }

    private func act(_ action: CueVoiceAction) {
        switch action {
        case .start: workspace.startVoiceCall()
        case .toggleMute:
            if let voice = workspace.voice { voice.setMuted(!voice.isMuted) }
        case .hangUp: workspace.voice?.hangUp()
        case .stopExecution:
            let targets = workspace.stoppableVoiceExecutions
            if targets.count == 1, let target = targets.first { stop(target.state.sessionID) }
            else if !targets.isEmpty { choosingExecution = true }
        case .recover(let recovery):
            Task {
                do { try await workspace.recoverVoice(recovery) }
                catch { workspace.fail(error) }
            }
        case .requestRepeat(let id): workspace.voice?.repeatReply(id)
        case .expand: workspace.voiceExpanded = true
        case .collapse: workspace.voiceExpanded = false
        }
    }

    private func stop(_ id: String) {
        Task {
            do { _ = try await workspace.stopVoiceExecution(id) }
            catch { workspace.fail(error) }
        }
    }
}

/// 栏头以下的通话与对话：回复区的占用只读 FloatingReply 的实测值。
/// 回复区在外层独立排版，通话只消耗剩余高度，不回写几何状态；开合始终保留同一个对话视图。
struct CueVoiceContent<Chat: View>: View {
    @ViewBuilder let chat: Chat
    @Environment(Workspace.self) private var workspace
    @Environment(\.chatBottomInset) private var replyHeight

    var body: some View {
        GeometryReader { room in
            VStack(spacing: 0) {
                if workspace.voice != nil {
                    CueVoicePanel(availableHeight: max(0, room.size.height - replyHeight))
                }
                chat.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 回复区先取自然高度，超出页面预算时只缩视口，卡片与草稿保留原有排版。
struct CueVoiceReplyBudget: Layout {
    let maximumHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: maximumHeight.map { min(ideal.height, $0) } ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
