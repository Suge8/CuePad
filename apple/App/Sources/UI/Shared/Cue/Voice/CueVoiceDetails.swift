import SwiftUI

/// 有界详情列执行、停止、未落库问题和朗读记录；结果只给辨认摘录，正文沿用原聊天的 SpeechBubble。
struct CueVoiceDetails: View {
    /// 浮层持有内容视图；在 body 内读取，保证开着详情时也观察接通与提交状态。
    let presentation: () -> CueVoicePresentation?
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        if let presentation = presentation() { details(presentation) }
    }

    private func details(_ presentation: CueVoicePresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("通话详情").font(Typography.title)
            if presentation.activity != .failed {
                Text(presentation.title).font(Typography.body).foregroundStyle(palette.ink2)
            }
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
                    if !presentation.readings.isEmpty {
                        Text("朗读记录").font(Typography.bodyStrong)
                        ForEach(presentation.readings) { reading in
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                Text(verbatim: reading.excerpt).font(Typography.body).lineLimit(1)
                                Text(verbatim: reading.status).font(Typography.meta).foregroundStyle(palette.ink2)
                                if let recovery = reading.recovery {
                                    Button { action(.recover(recovery)) } label: { Text(recovery.title) }
                                        .buttonStyle(ControlButtonStyle(size: .compact))
                                }
                            }
                        }
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
