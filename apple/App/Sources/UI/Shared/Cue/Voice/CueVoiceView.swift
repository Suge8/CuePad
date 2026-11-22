import SwiftUI

struct CueVoiceDetailButton<Label: View>: View {
    @Binding var source: BubbleSource?
    var activate: (() -> Void)?
    @ViewBuilder let label: () -> Label
    @State private var frame: CGRect?

    var body: some View {
        Button {
            if let activate { activate() }
            else { source = frame.map { .control($0) } ?? .unanchored }
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
struct CueVoiceView: View {
    let presentation: CueVoicePresentation?
    @Binding var detailsSource: BubbleSource?
    let action: (VoiceAction) -> Void
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

    private var showsStatus: Bool {
        guard let presentation, presentation.activity != .idle else { return false }
        return active || hasDetails || presentation.activity == .failed
    }

    @ViewBuilder private var content: some View {
        if showsStatus { bar.transition(.opacity) }
    }

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
        Button { action(.setMuted(!muted)) } label: {
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

private extension View {
    func voiceSlot(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .animation(Motion.fade, value: visible)
            .disabled(!visible)
            .allowsHitTesting(visible)
            .readerHidden(!visible)
    }
}
#endif
