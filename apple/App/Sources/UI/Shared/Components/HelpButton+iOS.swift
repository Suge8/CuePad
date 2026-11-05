#if os(iOS)
import SwiftUI
import UIKit

/// 系统导航栏里的问号（推入页与 sheet 的栏项：技能与规则、记忆与定时；全 App 栏里弹说明的只有它），两处同这一个：说明是同纸与面板上问号一样的气泡，
/// 挂在钮的下面、尾巴指着它（`BubbleSource.control`），画在窗口或 sheet 那一层（`PanelHost`）。
/// 栏里的项是系统按 SwiftUI 的钮另建的：建好之后系统不再跑它上面的 `onChange`（`bubble(isPresented:)` 靠它交出气泡，开不出来），
/// SwiftUI 量的框也对不上栏里真实的位置。所以钮里垫一个不占地方的平台视图（`Spot`），点下时由它量自己在窗口里的框，钮自己把气泡交给这一层。
/// 否决过：按读屏标识在窗口里找栏项（iOS 26 起栏项的视图不带标识，找不到，气泡没来源、压在页面第一行上）；
/// 系统 popover（iOS 26 起从栏项原地长出、盖住钮和第一行，不画箭头）。
/// 内容在气泡自己的视图体里求值：开着时跟着数据变。
struct BarHelpButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(PanelHost.self) private var host
    @Environment(\.self) private var environment
    @State private var token = UUID()
    @State private var spot = Spot.Box()

    var body: some View {
        Button {
            if host.shown?.token == token { return host.hide(token) }
            show()
        } label: {
            Image(.help).background { Spot(box: spot) }
        }
        .accessibilityLabel("说明")
        .debugOpensHelp(show)
        .onDisappear { host.hide(token) }
    }

    private func show() {
        host.present(
            token: token, key: token, source: spot.frame.map(BubbleSource.control) ?? .unanchored, width: .fitting,
            close: ClosePanel { [host, token] in host.hide(token) }, environment: environment, content: Live(content: content))
    }

    private struct Live: View {
        let content: () -> Content
        var body: some View { content() }
    }
}

/// 垫在栏里那颗钮底下的平台视图：点下时报它所在那颗钮在窗口里的框（往上找到系统给钮的那块玻璃，找不到就是自己），不读几何、不回写排版。
private struct Spot: UIViewRepresentable {
    let box: Box

    final class Box {
        weak var view: UIView?
        /// 钮在窗口里的框；还没进窗口为 nil。
        var frame: CGRect? {
            guard let view, view.window != nil else { return nil }
            let control = sequence(first: view, next: \.superview).first { $0 is UIControl } ?? view
            return control.convert(control.bounds, to: nil)
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        box.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
