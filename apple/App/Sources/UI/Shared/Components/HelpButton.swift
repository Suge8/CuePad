import SwiftUI

/// 问号钮：点开一段说明，从钮上长出的气泡（`bubble(isPresented:)`，两端同一个；Mac 不用系统 popover，理由见 docs/layout.md「气泡」）。
/// 纸与面板上是淡底圆钮（`round`），页顶那一排给 `.circular`。读屏名"说明"。
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

#if os(iOS)
/// 系统导航栏里的问号（推入页与 sheet 的栏项：技能与规则、记忆与定时），两处同这一个。栏里的项是系统按 SwiftUI 的按钮另建的：
/// 建好之后系统不再跑它上面的 `onChange`（`bubble(isPresented:)` 靠它把气泡交出去，开不出来），SwiftUI 量的框也对不上栏里真实的位置。
/// 所以点下时按读屏标识在窗口里量它的框（`PanelHost.frame(of:)`），由按钮自己把气泡交给这一层（`PanelHost.present`）。
/// 内容在气泡自己的视图体里求值：开着时跟着数据变，不是点下那一刻的快照。
struct BarHelpButton<Content: View>: View {
    /// 读屏标识：量框靠它，一个窗口里不重
    let id: String
    @ViewBuilder var content: () -> Content
    @Environment(PanelHost.self) private var host
    @Environment(\.self) private var environment
    @State private var token = UUID()

    var body: some View {
        Button("说明", icon: .help) {
            if host.shown?.token == token { return host.hide(token) }
            show()
        }
        .accessibilityIdentifier(id)
        .debugOpensHelp(show)
        .onDisappear { host.hide(token) }
    }

    private func show() {
        host.present(
            token: token, key: id, source: host.frame(of: id).map(BubbleSource.control) ?? .unanchored, width: .fitting,
            close: ClosePanel { [host, token] in host.hide(token) }, environment: environment, content: Live(content: content))
    }

    private struct Live: View {
        let content: () -> Content
        var body: some View { content() }
    }
}
#endif
