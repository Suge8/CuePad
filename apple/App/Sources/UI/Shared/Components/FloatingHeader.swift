#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// 推入页的顶栏（全 App 只此一种）：左边系统的圆形返回，中间一块玻璃（标题，下面一行要紧信息），右边最多一个圆钮
    /// （多个操作时调用方给一个"⋯"`Menu`）。顶上不做滚动模糊：滚上来的内容在状态栏与顶栏下淡到页面底色（`EdgeFade`；Mac 工具栏下是 `ToolbarEdge`），玻璃后面不叠字。
    /// `hidden` 时返回钮、中间那块与右边的圆钮都让开（淡到透明、不可点、读屏跳过），导航栏本身留着：
    /// 顶栏占的高度与安全区不变，内容的边距不跟着变（会话页看历史时用，见 `ChatFollow.showsHeader`）；
    /// 左缘右滑返回始终可用（`EdgeBackKeeper`）；给了 `reveal` 时让开的那一块仍接点按，点它唤出顶栏。
    /// 标题同时是读屏、返回菜单与多任务切换器里的名字。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: String, hidden: Bool = false, reveal: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(title: title, hidden: hidden, reveal: reveal, detail: detail(), trailing: trailing()))
    }

    /// 要紧信息是一行字、右边一个圆钮或"⋯"菜单。`detail` 为 nil 时只写标题；要等读库才有的信息先给空串，
    /// 那一行先留着位置，读到后标题不再上移。
    func floatingHeader<Trailing: View>(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        floatingHeader(title, detail: { HeaderDetail(text: detail) }, trailing: trailing)
    }

    /// 没有操作的页。
    func floatingHeader(_ title: String, detail: String? = nil) -> some View {
        floatingHeader(title, detail: detail) { EmptyView() }
    }
}

enum FloatingHeaderLayout {
    /// 与系统返回钮、工具栏圆钮同高；顶部的提示横幅让到它下面（`NoticeBanner`）。
    static let height: CGFloat = 44
}

private struct FloatingHeader<Detail: View, Trailing: View>: ViewModifier {
    /// 顶栏下沿往下再淡出这么高：刚滚到玻璃边上的字已经淡了。
    private static var fadeBelow: CGFloat { 18 }

    let title: String
    let hidden: Bool
    let reveal: (() -> Void)?
    let detail: Detail
    let trailing: Trailing
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) { EdgeFade(edge: .top, fade: Self.fadeBelow) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 系统的返回钮藏起时会淡出，但也会停掉左缘右滑返回：由 `EdgeBackKeeper` 把手势留住
            .navigationBarBackButtonHidden(hidden)
            .background(EdgeBackKeeper(active: hidden))
            // 两项推入时就建好、一直在，标题与信息只在项里面换，让开也只是透明：推入转场期间系统不重建工具栏项，
            // 换项要等转场结束才显示；中间这一项不在时系统还会把标题当普通文字摆回中间
            .toolbar {
                // 标题要等读库才有的页（卡片纸页）先透明，读到后淡入
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        detail
                    }
                    .padding(.horizontal, 16)
                    .frame(height: FloatingHeaderLayout.height)
                    .glass(in: .capsule)
                    .opacity(title.isEmpty || hidden ? 0 : 1)
                    .animation(Motion.quick, value: title.isEmpty || hidden)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .background {
                        if hidden, let reveal {
                            Color.clear.contentShape(.capsule).onTapGesture(perform: reveal).accessibilityHidden(true)
                        }
                    }
                }
                if Trailing.self != EmptyView.self {
                    ToolbarItem(placement: .primaryAction) {
                        trailing
                            .opacity(hidden ? 0 : 1)
                            .animation(Motion.quick, value: hidden)
                            .allowsHitTesting(!hidden)
                            .accessibilityHidden(hidden)
                    }
                    // 圆钮的玻璃是系统给的：让开时连它一起不画
                    .sharedBackgroundVisibility(hidden ? .hidden : .automatic)
                }
            }
    }
}

/// 返回钮藏起时左缘右滑返回照样可用。系统原来的代理在返回钮藏起时拒收右滑返回（经它的私有代理方法，公开方法拦不住），
/// 所以只在藏起期间把导航栈的两个右滑返回手势（左缘的与 iOS 26 内容区的）换成这里的代理：栈里不止一页、不在转场中、
/// 手指从左缘起手就放行（内容区那个只收左缘起手的，不和横向滚动抢）；返回钮回来时还原系统原来的代理，平时的取舍
/// 全是系统的。转场、跟手与取消回弹都是系统自己的。
private struct EdgeBackKeeper: UIViewControllerRepresentable {
    let active: Bool

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.active = active
        probe.apply()
    }

    final class Probe: UIViewController {
        var active = false
        private var installed: [(recognizer: UIGestureRecognizer, keeper: KeepBack)] = []

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        func apply() {
            guard active else { return restore() }
            guard installed.isEmpty, let navigation = navigationController else { return }
            for case let recognizer? in [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer] {
                let keeper = KeepBack(navigation: navigation, original: recognizer.delegate)
                recognizer.delegate = keeper
                installed.append((recognizer, keeper))
            }
        }

        private func restore() {
            for (recognizer, keeper) in installed where recognizer.delegate === keeper { recognizer.delegate = keeper.original }
            installed = []
        }
    }

    final class KeepBack: NSObject, UIGestureRecognizerDelegate {
        /// 从左缘起手算的宽度。
        private static let edge: CGFloat = 24
        weak var navigation: UINavigationController?
        weak var original: UIGestureRecognizerDelegate?

        init(navigation: UINavigationController, original: UIGestureRecognizerDelegate?) {
            self.navigation = navigation
            self.original = original
        }

        private var canPop: Bool {
            guard let navigation else { return false }
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool { canPop }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            canPop && touch.location(in: navigation?.view).x <= Self.edge
        }
    }
}

/// 顶栏玻璃里标题下的一行：小字、次要色、一行截断；nil 不占行，空串留着一行的位置。
private struct HeaderDetail: View {
    let text: String?
    @Environment(\.palette) private var palette

    var body: some View {
        if let text {
            Text(text.isEmpty ? " " : text).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                .contentTransition(.numericText())
                .animation(Motion.quick, value: text)
        }
    }
}
#endif
