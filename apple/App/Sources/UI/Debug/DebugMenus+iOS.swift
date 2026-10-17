#if os(iOS) && DEBUG
import UIKit

/// 截菜单用：`-CuePadMenuAt x,y`（窗口里的点，左上为原点）弹出那里按钮的菜单（顶栏的"⋯"、胶囊这类 `Menu`），弹好再报就绪，
/// `xc.sh shot` 截到的就是开着菜单的样子。系统没有从代码打开菜单的公开接口：找到盖住那一点、挂着 `UIContextMenuInteraction` 的最小视图，
/// 调它的私有方法 `_presentMenuAtLocation:`。列表行的长按菜单是 SwiftUI 按住才装上的，打不开，用 `DebugRowMenu` 把同一份菜单弹出来。只在 Debug 构建里。
extension DebugScene {
    static func openMenuIfAsked() async {
        guard let value = defaults.string(forKey: "CuePadMenuAt") else { return }
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        // 等页面排好、列表滚完
        try? await Task.sleep(for: .seconds(1.5))
        let point = CGPoint(x: parts[0], y: parts[1])
        var found: (view: UIView, interaction: UIContextMenuInteraction)?
        func walk(_ view: UIView) {
            if view.convert(view.bounds, to: window).contains(point),
               let interaction = view.interactions.lazy.compactMap({ $0 as? UIContextMenuInteraction }).first,
               found.map({ view.bounds.width * view.bounds.height < $0.view.bounds.width * $0.view.bounds.height }) ?? true {
                found = (view, interaction)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard let found, found.interaction.responds(to: selector) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(found.interaction.method(for: selector), to: Present.self)(found.interaction, selector, found.view.convert(point, from: window))
        // 菜单展开的动画
        try? await Task.sleep(for: .seconds(1))
    }
}
#endif
