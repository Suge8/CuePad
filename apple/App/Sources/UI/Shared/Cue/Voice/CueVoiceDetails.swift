import SwiftUI

/// 有界详情只列执行、停止和未落库的问题；已落库文字沿用原聊天的 SpeechBubble。
struct CueVoiceDetails: View {
    let presentation: CueVoicePresentation
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("通话详情").font(Typography.title)
            Text(presentation.title).font(Typography.body).foregroundStyle(palette.ink2)
            if presentation.canStopExecution {
                Button { action(.stopExecution) } label: { Label("停止执行", icon: .stop) }
                    .buttonStyle(ControlButtonStyle(size: .compact))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.block) {
                    ForEach(presentation.issues) { issue in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(issue.summary).font(Typography.bodyStrong)
                            Text(issue.message).font(Typography.body)
                            if let recovery = issue.recovery {
                                Button { action(.recover(recovery)) } label: { Text(recovery.title) }
                                    .buttonStyle(ControlButtonStyle(size: .compact))
                            }
                        }
                        .foregroundStyle(palette.failure)
                    }
                    ForEach(presentation.executions) { execution in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(verbatim: execution.title).font(Typography.bodyStrong)
                            Text(verbatim: execution.status).font(Typography.body)
                                .foregroundStyle(execution.needsAttention ? palette.failure : palette.ink2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
        }
        .padding(Spacing.panel)
    }
}
