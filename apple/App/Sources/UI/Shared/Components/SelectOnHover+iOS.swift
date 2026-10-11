#if os(iOS)
import SwiftUI

extension EnvironmentValues {
    /// 文字开行内选择（手机上只能整段复制）。会话的对话里关掉（`PiConversation`）：长按出的是消息菜单，挑字走菜单里的"选择文本"。
    @Entry var inlineTextSelection = true
}

extension View {
    /// 文字可选中（Mac 只在悬停的那一条开选择，见 `SelectOnHover+macOS`）。
    func selectableOnHover() -> some View { modifier(InlineSelection()) }
}

private struct InlineSelection: ViewModifier {
    @Environment(\.inlineTextSelection) private var enabled

    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content }
    }
}
#endif
