import SwiftUI

/// 会话条放不下时从窗口左缘拉出的抽屉：再窄的窗口（竖着的 iPad、拖小的 Mac 窗口）也够得着导航。
struct RailDrawer<Rail: View>: View {
    let open: Bool
    let close: () -> Void
    @ViewBuilder let rail: Rail

    var body: some View {
        ZStack(alignment: .leading) {
            if open { DrawerCatcher(close: close).transition(.identity) }
            rail
                .modifier(DrawerSurface(edge: .leading, ground: \.sidebar))
                .environment(\.pageActive, open)
                .modifier(DrawerSlide(open: open))
                .readerHidden(!open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
