import SwiftUI

/// 通话主体与操作位常驻：开始、关闭、失败都不挤动聊天；真实状态立即更新，只有声纹在图层里连续变形。
struct CueVoiceView<Operation: CueVoiceOperation>: View {
    let presentation: CueVoiceState<Operation>?
    @Binding var detailsSource: BubbleSource?
    let start: () -> Void
    let action: (CueVoiceIntent<Operation>) -> Void
    @Environment(\.palette) private var palette

    private var active: Bool { presentation?.active == true }
    private var closing: Bool { presentation?.activity == .closing }

    var body: some View {
        HStack(spacing: Spacing.item) {
            CueVoiceSignal(presentation: presentation)
            Text(presentation?.title ?? "和 Cue 通话")
                .font(Typography.meta.weight(.medium))
                .foregroundStyle(presentation?.activity == .failed ? palette.failure : palette.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { action(.toggleMute) } label: {
                // 两种字长共用同一槽位，切换不会推走挂断和详情。
                ZStack {
                    Text("取消静音").hidden()
                    Text(presentation?.muted == true ? "取消静音" : "静音")
                }
                .transaction { $0.animation = nil }
                .chip(on: presentation?.muted == true, size: .inline)
            }
            .buttonStyle(PressStyle())
            .disabled(presentation?.canMute != true || closing)
            Button {
                if active { action(.hangUp) } else { start() }
            } label: {
                Image(active ? .endSession : .audio)
                    .foregroundStyle(active ? palette.ink2 : palette.signature)
            }
            .buttonStyle(ControlButtonStyle(kind: .round, size: .compact))
            .disabled(closing || (!active && presentation?.startUnavailableReason != nil))
            .accessibilityLabel(active ? "挂断" : "和 Cue 通话")
            .help(Text(active ? "挂断" : presentation?.startUnavailableReason ?? "和 Cue 通话"))
            CueVoiceDetailButton(source: $detailsSource) {
                Image(presentation?.needsAttention == true ? .failure : .more)
                    .foregroundStyle(presentation?.needsAttention == true ? palette.failure : palette.ink2)
                    .frame(width: ControlSize.target, height: ControlSize.target)
                    .contentShape(.circle)
            }
            .disabled(presentation == nil)
            .accessibilityLabel("通话详情")
            .help(Text("通话详情"))
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.tight)
    }
}

/// 多个入口共用一个呈现来源；只量实际按钮，结束后的空通话栏不能充当锚点。
private struct CueVoiceDetailButton<Label: View>: View {
    @Binding var source: BubbleSource?
    var activate: (() -> Void)?
    @ViewBuilder let label: () -> Label
    @State private var frame: CGRect?

    var body: some View {
        Button {
            if let activate { activate() }
            else { source = frame.map(BubbleSource.control) ?? .unanchored }
        } label: { label() }
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

/// 配置排只占一个固定入口；问题与朗读记录统一从常驻通话栏的详情进入，结束时不再增高回复框。
/// 平台宿主提供同一份投影与 BubbleSource；开始动作不捕获、重造请求或媒体身份。
struct CueVoiceEntry<Operation: CueVoiceOperation>: View {
    let presentation: CueVoiceState<Operation>?
    @Binding var detailsSource: BubbleSource?
    let start: () -> Void

    var body: some View {
        let active = presentation?.active == true
        CueVoiceDetailButton(source: $detailsSource, activate: active ? nil : start) {
            Image(.audio).chip(on: active, size: .inline)
        }
        .disabled(!active && presentation?.startUnavailableReason != nil)
        .accessibilityLabel(active ? "通话详情" : "和 Cue 通话")
        .help(Text(active ? "通话详情" : presentation?.startUnavailableReason ?? "和 Cue 通话"))
    }
}
