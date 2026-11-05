import SwiftUI

/// 会话条放不下时（窗口窄过 `WideMetrics.railThreshold`）用户要它：从窗口左缘拉出、盖在主区上（`Workspace.railDrawer`），同 Cue 放不下时的右缘抽屉——
/// 再窄的窗口（竖着的 iPad、拖小的 Mac 窗口）也够得着导航。面同开着的会话条（贴边、底色从窗口顶铺到底），右缘一道发丝边、面板阴影；开合是渲染端的平移（`DrawerSlide`）。
/// 点外面关、那一下不落到下面（同右缘抽屉），Esc 同关，去了别处（`selectWide`、打开会话）也关。关着时滑在窗外、点不到、不放循环动效、读屏跳过。
struct RailDrawer<Rail: View>: View {
    let open: Bool
    let close: () -> Void
    @ViewBuilder let rail: Rail
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .leading) {
            if open {
                Color.clear.contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in close() })
                    .overlay { Button("关闭", action: close).keyboardShortcut(.escape, modifiers: []).opacity(0).accessibilityHidden(true) }
                    .ignoresSafeArea()
                    .transition(.identity)
            }
            rail
                // 影子只挂在底那块上（同 `DrawerSurface`）
                .background { palette.sidebar.elevation(.panel).ignoresSafeArea() }
                .overlay(alignment: .trailing) { palette.hair.frame(width: ControlMetrics.stroke).ignoresSafeArea() }
                .environment(\.pageActive, open)
                .modifier(DrawerSlide(open: open, edge: .leading))
                .readerHidden(!open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
