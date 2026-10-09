import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// 会话里的文字可选中。Mac：只给鼠标悬停着的这一条开选择，离开后关掉，所以拖选总是从悬停的那条开始。
    /// 文字选择（`textSelection`）每个文本都要另建一套排版，一屏回答全带上选择时点开会话的帧耗时多约三成。
    func selectableOnHover() -> some View {
        #if os(macOS)
        modifier(SelectOnHover())
        #else
        textSelection(.enabled)
        #endif
    }
}

#if os(macOS)
private struct SelectOnHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        Group {
            if hovering { content.textSelection(.enabled) } else { content }
        }
        .onHover { inside in
            // 拖选时指针会出界：按着鼠标时不关，选区才不会拖到一半没了；松开后下一次进出再关
            if inside || NSEvent.pressedMouseButtons == 0 { hovering = inside }
        }
    }
}
#endif
