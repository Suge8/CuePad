#if os(iOS)
import SwiftUI
import UIKit

/// 让 tab 的页一直留在窗口里：系统标签栏只把选中的页挂在窗口上，切走的页摘下，切回来再挂上——挂回窗口时 SwiftUI 把整页重新排、重新画
/// （进展页的看板在模拟器上要多一百多百万条指令），没去过的 tab 第一次选中才现建整页、读库（250ms 级）。
/// SwiftUI 的 `TabView` 背后是 UIKit 的标签栏控制器，页是各 `UITab` 的 `viewController`。这里在标签栏控制器的视图底下放一层藏着的视图（`Shelter`）：
/// - 切走的页画完切换的那一帧后挪进来（`Probe.viewDidDisappear`），切回来时系统把它挪回自己的容器，页始终没离开窗口；
/// - 启动后空闲时把没去过的 tab 建出来：先插在选中的页底下（被它盖着）、照系统选中时那样走一遍出现（页里导航栈的第一次出现在这时付），画两帧，
///   安全区与选中的页一样、字与图都画过，再照消失挪进来，第一次切过去就是回访。
///   一次建一个，之间再等一阵（时机同 Mac 的 `Prewarm.delay`）。
/// 藏着的视图里安全区不更新：页在容器里排好了再挪进来，回到容器时安全区没变，不重排；直接在藏着的视图里建出来的页安全区是 0，第一次选中要整页重排。
/// 藏着的页不订阅（`pageActive`），没读过的先读一份（`pagePrefetch`）。
/// 被否决的：透明（alpha 0）代替藏着——安全区跟着变，每次挪动都整页重排；按 SwiftUI 另建一份同样的页先挂着——第二份视图树与环境，选中时还得换成它。
struct DockShelter: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) {}

    /// 挂在每个 tab 里：第一个出现的去建别的 tab（已经建过的跳过，几个一起出现也只建一遍）；它所在的 tab 被切走时把页收进藏着的视图。
    final class Probe: UIViewController {
        private var warming: Task<Void, Never>?
        private weak var page: UIViewController?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard warming == nil, let bar = tabBarController else { return }
            warming = Task { [weak bar] in
                for tab in bar?.tabs ?? [] {
                    guard (try? await Task.sleep(for: DockShelter.delay)) != nil, let bar else { return }
                    await DockShelter.build(tab, in: bar)
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            page = sequence(first: self as UIViewController, next: \.parent).first { $0.parent is UITabBarController }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            warming?.cancel()
            warming = nil
            guard let page, let bar = page.tabBarController else { return }
            Task { [weak page, weak bar] in
                await NextFrame.drawn()
                guard let page, let bar, page.view.window == nil else { return }
                DockShelter.shelter(in: bar).addSubview(page.view)
            }
        }
    }

    static let delay: Duration = .seconds(2)

    private static func build(_ tab: UITab, in bar: UITabBarController) async {
        guard tab != bar.selectedTab, tab.viewController?.isViewLoaded == false, let page = tab.viewController,
              let shown = bar.selectedTab?.viewController?.view, let container = shown.superview else { return }
        // 建出来的页走一遍出现时，SwiftUI 按它（tab 的根页，留着标签栏）改标签栏的显隐：选中的页让开标签栏时（设置、技能与规则）建完放回去
        let hidden = bar.isTabBarHidden
        defer { if bar.isTabBarHidden != hidden { bar.setTabBarHidden(hidden, animated: false) } }
        page.view.frame = shown.frame
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        page.beginAppearanceTransition(true, animated: false)
        container.insertSubview(page.view, belowSubview: shown)
        page.endAppearanceTransition()
        await NextFrame.drawn()
        guard bar.selectedTab != tab, page.view.superview === container else { return }
        page.beginAppearanceTransition(false, animated: false)
        shelter(in: bar).addSubview(page.view)
        page.endAppearanceTransition()
    }

    private static func shelter(in bar: UITabBarController) -> UIView {
        if let shelter = bar.view.subviews.first(where: { $0 is Shelter }) { return shelter }
        let shelter = Shelter(frame: bar.view.bounds)
        shelter.isHidden = true
        shelter.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.view.insertSubview(shelter, at: 0)
        return shelter
    }

    private final class Shelter: UIView {}
}
#endif
