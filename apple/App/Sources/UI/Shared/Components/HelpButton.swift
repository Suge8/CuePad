import SwiftUI

/// 系统导航栏里的项不用它（栏里建好的项不再跑 `onChange`，开不出来）：用 `BarHelpButton`。
/// 说明只放不影响操作的解释；操作前必须知道的后果写在按钮旁，不收进这里。
struct HelpButton<Content: View>: View {
    var kind = ControlButtonStyle.Kind.round
    var size = ControlSize.compact
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(.help) }
            .debugOpensHelp { open = true }
            .buttonStyle(ControlButtonStyle(kind: kind, size: size))
            .help("说明")
            .accessibilityLabel("说明")
            .bubble(isPresented: $open) { content }
    }
}
