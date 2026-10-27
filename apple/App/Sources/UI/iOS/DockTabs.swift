#if os(iOS)
import SwiftUI
import UIKit

/// 底部那一排左边的两格去处：系统标签栏（`UITabBar`）。按住拖动时选中块的液态透镜、读屏的标签语义、辅助字号下的大内容查看器都是它自带的，
/// 自绘的玻璃拿不到透镜（SwiftUI 的玻璃只有按下回弹，透镜是系统私有的）。
/// 系统标签栏把悬浮边距（左、右、下各 21 点，iOS 27 实测）算在自己的范围里，玻璃底板是范围减去边距：范围连同边距铺到屏幕左下角，
/// 底板正好落在这一排左边那块的位置（`Dock.margin` 与它同值，底板宽 `Dock.capsule`、高 `Dock.height`）。系统改了边距这里会与 Cue 钮错开，大版本升级时截图核对。
/// 底板去不掉（透明外观也还在），也不能逐帧改宽（两格跟着挤扁）：换形里只淡入淡出（`DockHandoff.tabs`）。
/// 选中哪格只从 tab 推出来（`DockMotion.tab`），透镜由系统滑过去。
/// 字号与图标大小用系统的；"项目"那一格在同步到不了 Mac 时带一个点（`AppServices.macAlert`），系统角标比它大一圈，所以点是自己画在格子上的。
struct DockTabs: View {
    let motion: DockMotion
    /// 这一排有多宽（`DockBar`）。
    let width: CGFloat
    /// 两格展开着："进展"那一格是接力的落点。
    let relays: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        TabBar(selected: motion.tab, alert: services.macAlert?.title, tint: palette.signature, ink: palette.ink) { workspace.tap($0) }
            .frame(width: Dock.capsule(in: width) + Dock.margin * 2, height: Dock.height + Dock.margin)
            .overlay(alignment: .topLeading) { marks }
            .offset(x: -Dock.margin, y: Dock.margin)
    }

    /// 底板里第 index 格的位置（底板在边距之内；格子之间不留空，两端各 `Dock.inset`，同系统的排法）。
    private func slot(_ index: Int) -> CGRect {
        let cell = Dock.cell(in: width)
        return CGRect(x: Dock.margin + Dock.inset + cell * CGFloat(index), y: Dock.inset, width: cell, height: Dock.height - Dock.inset * 2)
    }

    private var marks: some View {
        let progress = slot(Dock.places.firstIndex(of: .progress) ?? 0)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: progress.width, height: progress.height)
                .relaySpot(dock: relays)
                .padding(.leading, progress.minX).padding(.top, progress.minY)
            if let alert = services.macAlert, let projects = Dock.places.firstIndex(of: .projects) {
                let icon = slot(projects)
                Circle().fill(palette.color(alert.tone)).frame(width: Self.dot, height: Self.dot)
                    .padding(.leading, icon.midX + Self.dotOffset.width).padding(.top, icon.minY + Self.dotOffset.height)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private static let dot: CGFloat = 7
    /// 点在图标右上角（系统把图标放在格子上部正中）。
    private static let dotOffset = CGSize(width: 9, height: 5)
}

/// 选中只在 `selected` 变了时写回：点格子时系统先把透镜滑过去，途中别的更新不把选中拉回旧格。
private struct TabBar: UIViewRepresentable {
    let selected: Int?
    let alert: String?
    let tint: Color
    let ink: Color
    let select: (Route) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.items = Dock.places.enumerated().map { UITabBarItem(title: $1.title, image: $1.icon.platformImage, tag: $0) }
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        let coordinator = context.coordinator
        coordinator.select = select
        bar.tintColor = UIColor(tint)
        bar.unselectedItemTintColor = UIColor(ink)
        bar.items?.first { $0.tag == Dock.places.firstIndex(of: .projects) }?.accessibilityValue = alert
        guard coordinator.selected != selected else { return }
        coordinator.selected = selected
        bar.selectedItem = selected.flatMap { bar.items?[$0] }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITabBar, context: Context) -> CGSize? {
        proposal.width.flatMap { width in proposal.height.map { CGSize(width: width, height: $0) } }
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (Route) -> Void = { _ in }
        var selected: Int?

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) { select(Dock.places[item.tag].route) }
    }
}
#endif
