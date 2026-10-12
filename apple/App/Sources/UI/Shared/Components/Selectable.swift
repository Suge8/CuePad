import SwiftUI

#if os(iOS)
extension EnvironmentValues {
    /// 文字开行内选择（手机上只能整段复制）。会话的对话里关掉（`PiConversation`）：长按出的是消息菜单，挑字走菜单里的"选择文本"。
    @Entry var inlineTextSelection = true
}
#endif

extension View {
    /// 一段文字可选中：Mac 常开（一条回答是一段 `Text`，气泡也是；不做"悬停才开"，开关要换结构、每个块挂一份跟踪区）；手机只能整段复制，对话里关掉。
    @ViewBuilder func selectable() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        modifier(InlineSelection())
        #endif
    }
}

#if os(iOS)
private struct InlineSelection: ViewModifier {
    @Environment(\.inlineTextSelection) private var enabled

    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content }
    }
}
#endif
