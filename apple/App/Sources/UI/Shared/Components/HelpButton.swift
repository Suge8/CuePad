import SwiftUI

/// 问号钮：点开一段说明，从钮上长出的气泡（Mac 经 `bubble(isPresented:)`、不用系统 popover，理由见 docs/layout.md「气泡」；
/// 手机按读屏标识量钮的框，`ControlAnchor`）。纸与面板上是淡底圆钮（`round`），页顶那一排给 `.circular`。读屏名"说明"。
/// 说明只放不影响操作的解释；操作前必须知道的后果写在按钮旁，不收进这里。
struct HelpButton<Content: View>: View {
    var kind = ControlButtonStyle.Kind.round
    var size = ControlSize.compact
    @ViewBuilder var content: Content
    @State private var open = false
    #if os(iOS)
    @State private var anchor = ControlAnchor("help.\(UUID().uuidString)")
    @State private var source: BubbleSource?
    #endif

    var body: some View {
        Button {
            #if os(iOS)
            source = anchor.frame.map(BubbleSource.control)
            #endif
            open.toggle()
        } label: {
            Image(.help)
        }
        .buttonStyle(ControlButtonStyle(kind: kind, size: size))
        .help("说明")
        .accessibilityLabel("说明")
        #if os(macOS)
        .bubble(isPresented: $open) { content }
        #else
        .accessibilityIdentifier(anchor.id)
        .background { ControlAnchor.Probe(anchor: anchor) }
        .panel(isPresented: $open, style: .bubble(source ?? .unanchored)) { content }
        #endif
    }
}
