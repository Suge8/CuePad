#if os(macOS)
import SwiftUI

/// 通话组件的宿主：开合与选择哪一件是呈现状态，业务动作全部回到 Workspace。
struct CueVoicePanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var choosingExecution = false

    var body: some View {
        Group {
            if let presentation = workspace.voicePresentation {
                CueVoiceView(presentation: presentation, expanded: workspace.voiceExpanded, action: act)
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
        case .recover:
            if let request = workspace.voiceRetryRequest {
                Task {
                    do { try await workspace.retryVoiceRequest(request.id) }
                    catch { workspace.fail(error) }
                }
            } else { workspace.startVoiceCall() }
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
#endif
