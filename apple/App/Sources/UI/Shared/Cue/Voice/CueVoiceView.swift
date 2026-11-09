import SwiftUI

/// 通话条：真实状态立即更新，只有声纹在图层里连续变形；进出与换态只淡、不挪，听、说、静音、结束都不改它的尺寸。
/// 手机与 iPad 只在通话中出现，盖在"对 Cue 说"那块玻璃上（`PhoneCall`）：静音在"＋"那一位、挂断在发送那一位，中间声纹与状态，点它看通话详情。
/// Mac 常驻在 Cue 栏顶上，开始、关闭、失败都不挤动聊天；详情在行尾的"⋯"。
struct CueVoiceView<Operation: CueVoiceOperation>: View {
    let presentation: CueVoiceState<Operation>?
    @Binding var detailsSource: BubbleSource?
    let action: (CueVoiceIntent<Operation>) -> Void
    @Environment(\.palette) private var palette

    private var active: Bool { presentation?.active == true }
    private var closing: Bool { presentation?.activity == .closing }
    private var muted: Bool { presentation?.muted == true }
    private var hasDetails: Bool {
        guard let presentation else { return false }
        return active || !presentation.issues.isEmpty || !presentation.readings.isEmpty
            || !presentation.executions.isEmpty || presentation.canStopExecution
            || presentation.requestPage != nil || presentation.replyPage != nil || presentation.executionPage != nil
    }

    var body: some View {
        content
            .onChange(of: hasDetails) { _, available in
                if !available { detailsSource = nil }
            }
    }

    #if os(iOS)
    private var content: some View {
        HStack(spacing: 0) {
            muteButton
            CueVoiceDetailButton(source: $detailsSource) {
                HStack(spacing: Spacing.item) {
                    CueVoiceSignal(presentation: presentation)
                    status.lineLimit(1)
                    if presentation?.needsAttention == true {
                        Image(.failure).foregroundStyle(palette.failure).readerHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .disabled(!hasDetails)
            .accessibilityLabel(Text(presentation?.title ?? "和 Cue 通话"))
            .accessibilityValue(presentation?.needsAttention == true ? Text("有问题") : Text(verbatim: ""))
            .accessibilityHint(Text("通话详情"))
            hangUpButton
        }
    }

    private var status: some View {
        Text(presentation?.title ?? "和 Cue 通话")
            .font(Typography.body)
            .foregroundStyle(palette.ink2)
            .contentTransition(.opacity)
            .animation(Motion.fade, value: presentation?.title.key)
    }

    /// 与"＋"同一种圆钮；静音时换成划掉的麦克风、底深一档（同选中的胶囊）。
    private var muteButton: some View {
        Button { action(.toggleMute) } label: {
            CircleGlyph(fill: muted ? palette.selection : palette.fill) {
                Image(muted ? .muted : .microphone)
                    .font(Glyph.control.weight(.semibold)).foregroundStyle(palette.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: ComposerMetrics.slot)
            .animation(Motion.fade, value: muted)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel("静音")
        .accessibilityAddTraits(muted ? .isSelected : [])
        .voiceSlot(presentation?.canMute == true && !closing)
    }

    private var hangUpButton: some View {
        Button { action(.hangUp) } label: {
            SendGlyph(.hangUp).frame(width: ComposerMetrics.slot)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel("结束通话")
        .voiceSlot(active && !closing)
    }
    #else
    private var showsStatus: Bool { active || hasDetails || presentation?.activity == .failed }

    private var content: some View {
        HStack(spacing: Spacing.item) {
            CueVoiceSignal(presentation: presentation).voiceSlot(showsStatus)
            status.lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .voiceSlot(showsStatus)
            muteButton
            hangUpButton
            CueVoiceDetailButton(source: $detailsSource) {
                Image(presentation?.needsAttention == true ? .failure : .more)
                    .foregroundStyle(presentation?.needsAttention == true ? palette.failure : palette.ink2)
                    .frame(width: ControlSize.target, height: ControlSize.target)
                    .contentShape(.circle)
            }
            .voiceSlot(hasDetails)
            .accessibilityLabel("通话详情")
            .help(Text("通话详情"))
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.tight)
    }

    private var status: some View {
        Text(presentation?.title ?? "和 Cue 通话")
            .font(Typography.meta.weight(.medium))
            .foregroundStyle(presentation?.activity == .failed ? palette.failure : palette.ink2)
    }

    private var muteButton: some View {
        Button { action(.toggleMute) } label: {
            ZStack {
                Text("取消静音").hidden()
                Text(muted ? "取消静音" : "静音")
            }
            .transaction { $0.animation = nil }
            .chip(on: muted, size: .inline)
            .frame(minWidth: ControlSize.target, minHeight: ControlSize.target)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .voiceSlot(presentation?.canMute == true && !closing)
    }

    private var hangUpButton: some View {
        Button { action(.hangUp) } label: {
            Text("结束")
                .chip(size: .inline)
                .frame(minWidth: ControlSize.target, minHeight: ControlSize.target)
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("结束通话")
        .help(Text("结束通话"))
        .voiceSlot(active && !closing)
    }
    #endif
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
