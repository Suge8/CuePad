import SwiftUI

/// 活动通话只占一行；关闭中的等待由连接阶段决定，不遮住原聊天。
struct CueVoiceView: View {
    let presentation: CueVoicePresentation
    @Binding var detailsSource: BubbleSource?
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
            CueVoiceDetailButton(source: $detailsSource) {
                Text("详情").foregroundStyle(presentation.needsAttention ? palette.failure : palette.ink2)
                    .chip(size: .inline)
            }
            .accessibilityLabel("通话详情")
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.tight)
    }
}

/// 多个入口共用一个呈现来源；只量实际按钮，结束后的空通话栏不能充当锚点。
private struct CueVoiceDetailButton<Label: View>: View {
    @Binding var source: BubbleSource?
    @ViewBuilder let label: () -> Label
    @State private var frame: CGRect?

    var body: some View {
        Button { source = frame.map(BubbleSource.control) ?? .unanchored } label: { label() }
            .buttonStyle(PressStyle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { next in
                if let frame, source == .control(frame) { source = .control(next) }
                frame = next
            }
            .onDisappear {
                if let frame, source == .control(frame) { source = nil }
            }
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
        if active {
            CueVoiceDetailButton(source: Bindable(workspace).voiceDetails) {
                Image(.audio).chip(on: true, size: .inline)
            }
            .accessibilityLabel("通话详情")
            .help(Text("通话详情"))
        } else {
            Button { workspace.startVoiceCall() } label: {
                Image(.audio).chip(size: .inline)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("和 Cue 通话")
            .help(Text("和 Cue 通话"))
        }
        if !active, let presentation, presentation.needsAttention || !presentation.executions.isEmpty || !presentation.readings.isEmpty {
            CueVoiceDetailButton(source: Bindable(workspace).voiceDetails) {
                Image(presentation.needsAttention ? .failure : .readFile)
                    .foregroundStyle(presentation.needsAttention ? palette.failure : palette.ink2).chip(size: .inline)
            }
            .accessibilityLabel(presentation.needsAttention ? "需注意" : "通话详情")
            .help(presentation.needsAttention ? Text("需注意") : Text("通话详情"))
        }
    }
}
#endif
