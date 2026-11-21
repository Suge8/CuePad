#if os(macOS)
import AppKit
import SwiftUI

/// 点开 AppKit 菜单的钮（`AgentCapsule`）记下自己的视图，菜单从它下面弹出。
final class PopUpAnchor {
    weak var view: NSView?
}

extension View {
    func popUpAnchor(_ anchor: PopUpAnchor?) -> some View {
        background { if let anchor { PopUpAnchorView(anchor: anchor) } }
    }
}

private struct PopUpAnchorView: NSViewRepresentable {
    let anchor: PopUpAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
#endif
