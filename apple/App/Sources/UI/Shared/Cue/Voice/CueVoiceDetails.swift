import SwiftUI

/// 有界详情列执行、停止、未落库问题和朗读记录；标题旁始终可一步结束通话，停止执行仍属于对应的工作。
/// 结果只给辨认摘录，正文沿用原聊天的 SpeechBubble。
struct CueVoiceDetails<Operation: CueVoiceOperation>: View {
    /// 浮层持有内容视图；在 body 内读取，保证开着详情时也观察接通与提交状态。
    let presentation: () -> CueVoiceState<Operation>?
    let action: (CueVoiceIntent<Operation>) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        if let presentation = presentation() { details(presentation) }
    }

    private func details(_ presentation: CueVoiceState<Operation>) -> some View {
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
            if presentation.activity != .failed {
                Text(presentation.title).font(Typography.body).foregroundStyle(palette.ink2)
            }
            if presentation.canStopExecution {
                Button { action(.stopExecution) } label: { Label("停止执行", icon: .stop) }
                    .buttonStyle(ControlButtonStyle(size: .compact))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.block) {
                    if presentation.executionPage != nil { Text("执行记录").font(Typography.bodyStrong) }
                    ForEach(presentation.executions) { execution in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(verbatim: execution.title).font(Typography.bodyStrong)
                            Text(verbatim: execution.status).font(Typography.body)
                                .foregroundStyle(execution.needsAttention ? palette.failure : palette.ink2)
                            if let stop = execution.stop {
                                Button { action(.perform(stop)) } label: { Label("停止执行", icon: .stop) }
                                    .buttonStyle(ControlButtonStyle(size: .compact))
                            }
                        }
                    }
                    navigation(presentation.executionPage)
                    if presentation.requestPage != nil { Text("请求记录").font(Typography.bodyStrong) }
                    ForEach(presentation.issues) { issue in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(issue.summary).font(Typography.bodyStrong)
                            Text(issue.message).font(Typography.body)
                            if let recovery = issue.recovery {
                                Button { action(.perform(recovery)) } label: { Text(recovery.title) }
                                    .buttonStyle(ControlButtonStyle(size: .compact))
                            }
                        }
                        .foregroundStyle(palette.failure)
                    }
                    navigation(presentation.requestPage)
                    if !presentation.readings.isEmpty || presentation.replyPage != nil {
                        Text("朗读记录").font(Typography.bodyStrong)
                        ForEach(presentation.readings) { reading in
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                Text(verbatim: reading.excerpt).font(Typography.body).lineLimit(1)
                                Text(verbatim: reading.status).font(Typography.meta).foregroundStyle(palette.ink2)
                                if let recovery = reading.recovery {
                                    Button { action(.perform(recovery)) } label: { Text(recovery.title) }
                                        .buttonStyle(ControlButtonStyle(size: .compact))
                                }
                            }
                        }
                    }
                    navigation(presentation.replyPage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
        }
        .padding(Spacing.panel)
    }

    @ViewBuilder private func navigation(_ page: CueVoiceState<Operation>.Page?) -> some View {
        if let page {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let error = page.error {
                    Text(error).font(Typography.meta).foregroundStyle(palette.failure)
                }
                if page.loading { Text("正在读取…").font(Typography.meta).foregroundStyle(palette.ink2) }
                HStack(spacing: Spacing.item) {
                    if let first = page.first {
                        Button { action(.perform(first)) } label: { Text("回到首页") }
                    }
                    if let next = page.next {
                        Button { action(.perform(next)) } label: { Text("下一页") }
                    }
                }
                .buttonStyle(ControlButtonStyle(size: .compact))
                .disabled(page.loading)
            }
        }
    }

}
