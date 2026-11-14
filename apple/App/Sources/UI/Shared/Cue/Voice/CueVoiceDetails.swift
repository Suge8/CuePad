import SwiftUI

/// 有界详情列执行（每行自己的停止）、未落库问题和朗读记录；活动通话可从标题旁直接结束。Mac 与手机同一份。
/// 结果只给辨认摘录，正文沿用原聊天的 SpeechBubble。
struct CueVoiceDetails: View {
    /// 浮层持有内容视图；在 body 内读取，保证开着详情时也观察接通与提交状态。
    let presentation: () -> CueVoicePresentation?
    let action: (VoiceAction) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        if let presentation = presentation() { details(presentation) }
    }

    private func details(_ presentation: CueVoicePresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            HStack(spacing: Spacing.item) {
                Text("通话详情").font(Typography.title)
                Spacer(minLength: Spacing.item)
                Button { action(.hangUp) } label: { Text("结束通话") }
                    .buttonStyle(ControlButtonStyle(size: .compact))
                    .disabled(!presentation.active || presentation.activity == .closing)
                    .opacity(presentation.active ? 1 : 0)
                    .readerHidden(!presentation.active)
            }
            // 只在通话中写此刻的状态：结束了不留"通话已结束"，异常结束由提示条说
            if presentation.active {
                Text(presentation.title).font(Typography.body).foregroundStyle(palette.ink2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.block) {
                    ForEach(presentation.executions) { execution in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(verbatim: execution.title).font(Typography.bodyStrong)
                            Text(verbatim: execution.status).font(Typography.body)
                                .foregroundStyle(execution.needsAttention ? palette.failure : palette.ink2)
                            if let stop = execution.stop {
                                Button { action(stop) } label: { Label("停止执行", icon: .stop) }
                                    .buttonStyle(ControlButtonStyle(size: .compact))
                            }
                        }
                    }
                    ForEach(presentation.issues) { issue in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(issue.summary).font(Typography.bodyStrong)
                            Text(issue.message).font(Typography.body)
                            if let recovery = issue.recovery {
                                Button { action(recovery) } label: { Text(recovery.title) }
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
                                    Button { action(recovery) } label: { Text(recovery.title) }
                                        .buttonStyle(ControlButtonStyle(size: .compact))
                                }
                            }
                        }
                    }
                    if let earlier = presentation.earlier {
                        Text(earlier).font(Typography.meta).foregroundStyle(palette.ink2)
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
