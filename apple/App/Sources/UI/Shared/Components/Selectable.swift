import SwiftUI

#if os(iOS)
extension EnvironmentValues {
    @Entry var inlineTextSelection = true
}
#endif

extension View {
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
