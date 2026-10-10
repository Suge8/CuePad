#if os(iOS)
import SwiftUI

extension View {
    func presentPanel<Item: Identifiable>(
        item: Binding<Item?>, style: PanelStyle, close: ClosePanel, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        Group {
            if style == .fullScreen {
                self.fullScreenCover(item: item) { content($0).environment(\.closePanel, close) }
            } else {
                self.sheet(item: item) { content($0).environment(\.closePanel, close) }
            }
        }
    }
}
#endif
