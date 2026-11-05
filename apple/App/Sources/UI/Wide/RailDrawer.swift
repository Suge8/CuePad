import SwiftUI

/// 会话条放不下时（窗口窄过 `WideMetrics.railThreshold`）用户要它：从窗口左缘拉出、盖在主区上（`Workspace.railDrawer`），同 Cue 放不下时的右缘抽屉（`CueDock`）——
/// 再窄的窗口（竖着的 iPad、拖小的 Mac 窗口）也够得着导航。面同右缘抽屉（`DrawerSurface`：侧栏底、右缘发丝边、面板阴影）；开合是渲染端的平移（`DrawerSlide`）。
/// 点外面关、那一下不落到下面（同右缘抽屉，`DrawerCatcher`），Esc 同关，去了别处（`selectWide`、打开会话）、窗口跨过临界宽（`Workspace.fit`）也关。关着时滑在窗外、点不到、不放循环动效、读屏跳过。
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
