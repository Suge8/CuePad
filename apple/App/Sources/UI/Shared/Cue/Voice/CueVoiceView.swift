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
/// Mac 的通话条，常驻在 Cue 栏顶上：真实状态立即更新，只有声纹在图层里连续变形；开始、关闭、失败都不挤动聊天，详情在行尾的"⋯"。
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
