import SwiftUI

/// 活动通话只占一行；关闭中的等待由连接阶段决定，不遮住原聊天。
struct CueVoiceView: View {
    let presentation: CueVoicePresentation
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            CueVoiceSignal(samples: presentation.samples)
            Text(presentation.title)
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .lineLimit(1)
            Spacer(minLength: 0)
            if presentation.activity != .closing {
                Button { action(.toggleMute) } label: {
                    Text(presentation.muted ? "取消静音" : "静音")
                        .chip(on: presentation.muted, size: .inline)
                }
                .buttonStyle(PressStyle())
                .disabled(!presentation.canMute)
                Button(role: .destructive) { action(.hangUp) } label: {
                    Text("挂断").chip(size: .inline)
                }
                .buttonStyle(PressStyle())
            }
            Button { action(.details) } label: {
                Text("详情").foregroundStyle(presentation.needsAttention ? palette.failure : palette.ink2)
                    .chip(size: .inline)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("通话详情")
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.tight)
    }
}

#if os(macOS)
/// 沿用配置排的压缩与胶囊。结束后恢复发起，未解决的问题另有明确入口。
struct CueVoiceEntry: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let presentation = workspace.voicePresentation
        let active = presentation?.active == true
        Button {
            if active { workspace.voiceDetails = true }
            else { workspace.startVoiceCall() }
        } label: {
            Image(.audio).chip(on: active, size: .inline)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(active ? "通话详情" : "和 Cue 通话")
        .help(active ? Text("通话详情") : Text("和 Cue 通话"))
        if !active, let presentation, presentation.needsAttention || !presentation.executions.isEmpty {
            Button { workspace.voiceDetails = true } label: {
                Image(presentation.needsAttention ? .failure : .readFile)
                    .foregroundStyle(presentation.needsAttention ? palette.failure : palette.ink2).chip(size: .inline)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(presentation.needsAttention ? "需注意" : "通话详情")
            .help(presentation.needsAttention ? Text("需注意") : Text("通话详情"))
        }
    }
}
#endif
