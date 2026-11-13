import SwiftUI

/// 多个入口共用一个呈现来源；只量实际按钮，结束后的空通话栏不能充当锚点。
struct CueVoiceDetailButton<Label: View>: View {
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

#if os(macOS)
/// Mac 的通话条，在输入框那里：通话中顶替输入框（`CuePage`，同手机），挂断后还有可看的（失败、问题与朗读记录）时缩成输入框上面的一条，都没有就不在。
/// 真实状态立即更新，只有声纹在图层里连续变形，详情在行尾的"⋯"。
/// 手机与 iPad 没有单独的条：通话就在"对 Cue 说"里（`CueComposer`、`PhoneCall`）。
struct CueVoiceView<Operation: CueVoiceOperation>: View {
    let presentation: CueVoiceState<Operation>?
    @Binding var detailsSource: BubbleSource?
    let action: (CueVoiceIntent<Operation>) -> Void
    @Environment(\.palette) private var palette

    private var active: Bool { presentation?.active == true }
    private var closing: Bool { presentation?.activity == .closing }
    private var muted: Bool { presentation?.muted == true }
    private var hasDetails: Bool { presentation?.hasDetails == true }

    var body: some View {
        content
            .onChange(of: hasDetails) { _, available in
                if !available { detailsSource = nil }
            }
    }

    private var showsStatus: Bool { active || hasDetails || presentation?.activity == .failed }

    @ViewBuilder private var content: some View {
        if showsStatus { bar.transition(.opacity) }
    }

    /// 与手机通话中的输入框同一个摆法：左边静音、右边挂断两颗圆钮，中间声纹与状态居中、点它看通话详情。
    private var bar: some View {
        HStack(spacing: Spacing.item) {
            muteButton
            CueVoiceDetailButton(source: $detailsSource) {
                HStack(spacing: Spacing.item) {
                    CueVoiceSignal(presentation: presentation)
                    status.lineLimit(1)
                    if presentation?.needsAttention == true { Image(.failure).foregroundStyle(palette.failure) }
                }
                .frame(maxWidth: .infinity, minHeight: ComposerMetrics.glyphTarget)
                .contentShape(.rect)
            }
            .disabled(!hasDetails)
            .accessibilityLabel("通话详情")
            .help(Text("通话详情"))
            hangUpButton
        }
        .padding(Spacing.tight)
        .glass(in: .capsule)
        .padding(.bottom, active ? 0 : Spacing.item)
    }

    private var status: some View {
        Text(presentation?.title ?? "和 Cue 通话")
            .font(Typography.body)
            .foregroundStyle(presentation?.activity == .failed ? palette.failure : palette.ink2)
    }

    private var muteButton: some View {
        Button { action(.toggleMute) } label: {
            CircleGlyph(fill: muted ? palette.ink : palette.fill) {
                Image(muted ? .muted : .microphone).font(Glyph.large).foregroundStyle(muted ? palette.paper : palette.ink)
            }
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(muted ? "取消静音" : "静音")
        .help(Text(muted ? "取消静音" : "静音"))
        .voiceSlot(presentation?.canMute == true && !closing)
    }

    private var hangUpButton: some View {
        Button { action(.hangUp) } label: { SendGlyph(closing ? .stopping : .hangUp) }
            .buttonStyle(PressStyle(.button))
            .accessibilityLabel("结束通话")
            .help(Text("结束通话"))
            .voiceSlot(active)
            .disabled(closing)
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
            Image(.call).chip(on: active, size: .inline)
        }
        .disabled(!active && presentation?.startUnavailableReason != nil)
        .accessibilityLabel(active ? "通话详情" : "和 Cue 通话")
        .help(Text(active ? "通话详情" : presentation?.startUnavailableReason ?? "和 Cue 通话"))
    }
}

private extension View {
    /// 保留测量与视图身份；退出开始就撤掉点击、键盘与读屏入口，淡去只影响画面。
    func voiceSlot(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .animation(Motion.fade, value: visible)
            .disabled(!visible)
            .allowsHitTesting(visible)
            .readerHidden(!visible)
    }
}
#endif
