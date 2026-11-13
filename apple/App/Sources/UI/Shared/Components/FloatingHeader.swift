#if os(iOS)
import Synchronization
import SwiftUI

extension View {
    /// 页顶那一排全 App 只此一种（手机与 iPad、根页与推入页同一个）。画在哪由所在的地方定（`HeaderHost`），调用处不分。
    /// 推入页在系统导航栏里：中间与右边是导航栏里的两项，两项推入时就建好、一直在，标题与信息只在项里面换，让开也只是透明：推入转场期间系统不重建工具栏项，换项要等转场结束才显示；中间这一项不在时系统还会把标题当普通文字摆回中间。
    /// 页自己画的那一排（窄屏的 Cue 页、宽屏栏里的页）：从中间长出的面板（`GrowPanel`）只能在这里长，导航栏里的项按栏高摆、画不到栏外。
    /// `hidden` 时整排让开，占的高度不变，内容的边距不跟着变（会话页看历史时用，见 `ChatFollow.showsHeader`）；左缘右滑返回照常（`BarFade`）。给了 `reveal` 时让开的那一条仍接点按，点它整排一起回来。标题同时是读屏、返回菜单与多任务切换器里的名字。
    /// 中间那块玻璃随内容定宽，这一页开着时只长不缩（`Widening`）：状态那一行来回换（发送中、思考中、歇着、正在同步）时玻璃与标题都不动，
    /// 只在头一次出现更长的那一下当帧长宽（约 138 点）。否决过（#36，数据都与 main 交替 3 轮）：
    /// 玻璃连同字连续换宽——玻璃里每有一段动画主线程就连着忙一两秒，状态轮播时唤醒约为改前的三倍；
    /// 只在刷新最宽那一下带动画——系统导航栏在 SwiftUI 动画之外先把中间那一项撑到新宽，玻璃照样当帧到位；
    /// 状态行垫一行隐藏的最宽状态字、一打开就按终点宽排（同 Mac 的 `OverlayTitle`）——首次也不跳了，但玻璃常年顶到系统给的宽，状态轮播时渲染服务指令 +15%；
    /// 只长不缩但用几何读数写回下限——静置时渲染服务的指令多四成；玻璃铺满两侧圆钮之间；按最宽的样子固定占位。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: LocalizedStringResource, hidden: Bool = false, reveal: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(
            title: title, hidden: hidden, reveal: reveal,
            center: TitleStack(title: title, detail: detail()).padding(.horizontal, Spacing.block).headerPiece().opacity(String(localized: title).isEmpty ? 0 : 1),
            trailing: trailing()))
    }

    /// `hasPanel` 是页头的固定能力：会展开的名牌始终在页面浮层中，开合不改变安全区或实例位置。
    func floatingHeader<Center: View, Trailing: View>(
        _ title: LocalizedStringResource, height: CGFloat = FloatingHeaderLayout.height, hasPanel: Bool = false, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(title: title, hidden: false, reveal: nil, height: height, hasPanel: hasPanel, center: center(), trailing: trailing()))
    }

    /// `detail` 为 nil 时只写标题；要等读库才有的信息先给空串，那一行先留着位置，读到后标题不再上移。
    func floatingHeader<Trailing: View>(_ title: LocalizedStringResource, detail: Dotted? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        floatingHeader(title, detail: { HeaderDetail(text: detail) }, trailing: trailing)
    }

    func floatingHeader(_ title: LocalizedStringResource, detail: Dotted? = nil) -> some View {
        floatingHeader(title, detail: detail) { EmptyView() }
    }

    func headerPiece(interactive: Bool = false) -> some View { modifier(HeaderPiece(interactive: interactive)) }
}

enum HeaderHost: Equatable {
    case navigationBar
    case page
    case sidebar
    case panel
}

extension EnvironmentValues {
    @Entry var headerHost = HeaderHost.navigationBar
    @Entry var headerGivesWay = false
    @Entry var headerGrown = false
}

nonisolated enum FloatingHeaderLayout {
    /// 顶部的提示横幅与它同高、盖在中间那块的位置（`NoticeBanner`）。
    static let height: CGFloat = 44
    static let margin = Spacing.page
    static let slot = height + 8
    /// 这一排定高，字号跟着动态字体放大到这一档为止（同系统的导航栏与标签栏）：再大圆钮里的图标与中间那块的字就撑出这一排、把两颗圆钮挤出屏幕。
    /// 管这一排上收着的东西（圆钮、`headerPiece`、`GrowPanel` 的 `head`、提示横幅），长出来的面板不归它管。
    static let largestType = DynamicTypeSize.xxLarge
}

private struct FloatingHeader<Center: View, Trailing: View>: ViewModifier {
    let title: LocalizedStringResource
    let hidden: Bool
    let reveal: (() -> Void)?
    var height = FloatingHeaderLayout.height
    var hasPanel = false
    let center: Center
    let trailing: Trailing
    @State private var grown = false
    @Environment(\.headerHost) private var host
    @Environment(Workspace.self) private var workspace
    @Environment(ModalHost.self) private var modals: ModalHost?

    func body(content: Content) -> some View {
        let covered = modals?.modal?.inPage == true
        Group {
            switch host {
            case .sidebar:
                content.safeAreaPadding(.top, height + Bars.contentGap)
            case .page, .panel:
                let bar = PageBar(height: height, trailing: trailing.modifier(Yield(hidden: hidden)).readerHidden(covered)) {
                    middle.modifier(Yield(hidden: hidden)).readerHidden(covered && !grown).background { revealer(.capsule) }
                }
                .onPreferenceChange(Grown.self) { grown = $0 }
                if hasPanel {
                    // 原生栏外的按钮接不到点按；会展开的页头始终留在页面浮层，只让出收起高度。
                    content
                        .safeAreaPadding(.top, height + Bars.contentGap)
                        .readerHidden(covered)
                        .overlay(alignment: .top) { bar }
                } else {
                    content
                        .safeAreaPadding(.top, Bars.contentGap)
                        .readerHidden(covered)
                        .safeAreaBar(edge: .top, spacing: 0) { bar }
                }
            case .navigationBar:
                content
                    // 标题只在中间那块玻璃里：不在 `RouteView` 里的页（任务正文的编辑 sheet）也不能让系统在下面再排一个大标题
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // 中间这一项一直在：不在时系统会把标题当普通文字摆回中间
                        ToolbarItem(placement: .principal) { middle }
                            // 玻璃自己画，不再套一层系统的玻璃底（玻璃不叠玻璃）
                            .sharedBackgroundVisibility(.hidden)
                        if Trailing.self != EmptyView.self {
                            ToolbarItem(placement: .primaryAction) { trailing }
                        }
                    }
                    // 让开是整条导航栏一起淡（返回钮、中间、右边连同系统给的玻璃）；它淡到透明就不接点按，点让开的那一条唤出由内容顶上这一条接
                    .background { BarFade(hidden: hidden) }
                    .overlay(alignment: .top) { revealer(.rect).frame(height: 0).ignoresSafeArea(edges: .top) }
            }
        }
        .navigationTitle(Text(title))
        .environment(\.headerGivesWay, host != .panel && workspace.noticeOnHead)
        .animation(NoticeBanner.giveWay(workspace.noticeOnHead), value: workspace.noticeOnHead)
    }

    private var middle: some View {
        HStack(spacing: Spacing.item) { center }
    }

    @ViewBuilder private func revealer(_ shape: some Shape) -> some View {
        if hidden, let reveal {
            Color.clear.contentShape(shape).onTapGesture(perform: reveal).transition(.identity).readerHidden(true)
        }
    }
}

struct Grown: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// 否决过：藏返回钮（`navigationBarBackButtonHidden`、`hidesBackButton`）连带关掉左缘右滑返回；藏整条栏（`toolbarVisibility(.hidden)`）
/// 改安全区、内容跳一下，左缘右滑也跟着停；返回钮的系统玻璃不认 `sharedBackgroundVisibility`，藏不掉，留一块空玻璃。
/// 导航栏是整个栈共用的：这一页走开（推入下一页、返回，含左缘右滑的那一段）就放回不透明，转场取消回来再按 `hidden` 淡回去。
private struct BarFade: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) { controller.hidden = hidden }

    final class Controller: UIViewController {
        var hidden = false {
            didSet { if hidden != oldValue { apply(animated: true) } }
        }
        private var onTop = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onTop = true
            apply(animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onTop = false
            guard let bar = navigationController?.navigationBar else { return }
            bar.accessibilityElementsHidden = false
            if let coordinator = transitionCoordinator {
                coordinator.animate { _ in bar.alpha = 1 }
            } else {
                bar.alpha = 1
            }
        }

        private func apply(animated: Bool) {
            guard onTop, let bar = navigationController?.navigationBar else { return }
            bar.accessibilityElementsHidden = hidden
            let alpha: CGFloat = hidden ? 0 : 1
            DebugHooks.barFaded(hidden, navigation: navigationController)
            guard animated else { return bar.alpha = alpha }
            Motion.Fade.animate { bar.alpha = alpha }
        }
    }
}

private struct Yield: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .animation(Motion.fade, value: hidden)
            .allowsHitTesting(!hidden)
            .readerHidden(hidden)
    }
}

/// 整排的玻璃（两侧圆钮、中间那几块、长开的面板）在同一个玻璃容器里：彼此取样，名牌长开盖过侧栏钮时两块相融，不是玻璃叠玻璃。
/// 容器里的玻璃都挂在内容本身上（`glass`、`glassCircle`）：挂在空背景上的会被容器合成到字上面。相融的距离比相邻两块之间的缝小，静止时各是各的。
/// 两边让到 `headInset`：iPad 会话条藏起时，顶上那排浮着的钮压在主区左上，中间那块在让出后的宽里居中。
private struct PageBar<Middle: View, Trailing: View>: View {
    let height: CGFloat
    let trailing: Trailing
    @ViewBuilder let middle: Middle
    @Environment(\.headInset) private var inset

    var body: some View {
        GlassEffectContainer(spacing: Spacing.tight) {
            ZStack(alignment: .top) {
                HStack {
                    Spacer(minLength: Spacing.item)
                    trailing
                }
                .glassCircle()
                .frame(height: height)
                middle
            }
        }
        .padding(.leading, inset.leading)
        .padding(.trailing, inset.trailing)
    }
}

private struct HeaderPiece: ViewModifier {
    let interactive: Bool
    @Environment(\.headerGivesWay) private var givesWay
    @Environment(\.headerGrown) private var grown

    func body(content: Content) -> some View {
        // 先定高再上玻璃：玻璃随内容高时，没有第二行的标题（项目没写介绍）只剩一条细缝
        let piece = content.dynamicTypeSize(...FloatingHeaderLayout.largestType).frame(height: FloatingHeaderLayout.height)
        Group {
            if grown { piece } else { piece.glass(in: .capsule, interactive: interactive) }
        }
        .contentShape(.capsule)
        .opacity(givesWay && !grown ? 0 : 1)
    }
}

/// 顶栏文字保持身份：按说明的句式重建整组会把没变的标题一起淡空，玻璃上只剩近黑的字影。
/// 说明的数字过渡由 `HeaderDetail` 自己处理，不更换标题与布局容器。
private struct TitleStack<Detail: View>: View {
    let title: LocalizedStringResource
    let detail: Detail
    @Environment(\.palette) private var palette
    @State private var widest = Widening.Widest()

    var body: some View {
        Widening(widest: widest) {
            VStack(spacing: Spacing.hair) {
                Text(title).font(Typography.toolbarTitlePaired).foregroundStyle(palette.ink).lineLimit(1)
                detail
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 顶栏中间那块只长不缩：排过的最宽记在引用里，排版时直接取，不经几何读数、不写状态（那样多一遍排版，渲染服务静置时每帧多忙四成，#36）。
private struct Widening: Layout {
    let widest: Widest

    /// Layout 要 Sendable；排版其实都在主线程，锁只为过编译器的隔离检查，不争用。
    nonisolated final class Widest: Sendable {
        private let width = Mutex<CGFloat>(0)

        func grow(_ seen: CGFloat) -> CGFloat { width.withLock { $0 = max($0, seen); return $0 } }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        let width = min(widest.grow(size.width), proposal.width ?? .infinity)
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct HeaderDetail: View {
    let text: Dotted?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let text {
                (text.isEmpty ? Text(" ") : Text(text)).font(Typography.toolbarSubtitle.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1).rollingCount(text)
            }
        }
    }
}
#endif
