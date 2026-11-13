#if os(iOS)
import SwiftUI

extension View {
    func countsAsViewer() -> some View { modifier(CountsAsViewer()) }
}

private struct CountsAsViewer: ViewModifier {
    @Environment(AppServices.self) private var services
    @Environment(\.pageActive) private var active
    @State private var appeared = false
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true }
            // 页拆掉时 onChange 不再来：在这里收回
            .onDisappear {
                appeared = false
                count(false)
            }
            .onChange(of: appeared && active, initial: true) { _, on in count(on) }
    }

    private func count(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        services.sessionViewers += on ? 1 : -1
    }
}
#endif
