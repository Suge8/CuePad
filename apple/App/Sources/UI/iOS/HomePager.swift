#if os(iOS)
import SwiftUI
import UIKit

/// 窄屏根上的四页按底部那一排的顺序（`Dock.pages`）横着排成一条：左右滑跟手切页，松手按甩出的方向停到一页；点底部那一排换去处时整条滑过去。
/// 当前页只有 `Workspace.root` 一份：松手、点按都经 `select`；`position` 只是这一条此刻挪到第几页，跟着它走。
/// Cue 在最右，它右边是刚返回离开的那一页（`Workspace.forward`）：手指左滑把它拉回来。跟手的是离开前拍的快照（`LeaveShot`，同 Safari 的前进），
/// 同系统推入一样盖着 Cue 页滑进来、Cue 页与底部那一排慢慢退；松手推入真的页（不带动画），它画上屏后才收起快照。
/// 先排后动：页建过就留着（回访不重建、滚动位置还在），停稳之后才建两边的邻页，动的时候每帧只改位移。
/// 不在屏上的页暂停订阅与实时状态（`pageActive`），没读过的先读一份（`pagePrefetch`），一露出来就恢复。
/// 谁接横着的拖见 `PagerPan`；输入框有焦点时不接（选字、挪光标都是横着拖）。减弱动态效果时点按不滑、直接换。
struct HomePager<Chrome: View>: View {
    /// Cue 页的输入框有焦点。
    let composing: Bool
    let shot: LeaveShot
    /// 盖在页上、不随页滑的一层（底部那一排）：只在前进时随 Cue 页一起退。
    @ViewBuilder let chrome: Chrome
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    /// 这一条挪到第几页（Cue 右边的前进页是 `last + 1`）。
    @State private var position = CGFloat(Dock.order(Route.first))
    /// 手指这次拖了多远（点）。
    @State private var drag: CGFloat = 0
    @State private var built: Set<Route> = [Route.first]
    @State private var width: CGFloat = 0
    /// 前进松手后推入真的页，它画上屏之前快照还留着。
    @State private var handing: UIView?

    private static var last: Int { Dock.pages.count - 1 }
    /// 前进时 Cue 页退开的比例（同系统推入时下面那一页）。
    private static var parallax: CGFloat { 0.3 }

    var body: some View {
        let index = Dock.order(workspace.root)
        let ahead = forwardShot
        // 这一条此刻停在第几页（连续值）
        let shown = position - (width > 0 ? drag / width : 0)
        let pushed = min(max(shown - CGFloat(Self.last), 0), 1)
        ZStack {
            ForEach(Dock.pages, id: \.self) { route in
                let order = Dock.order(route)
                let x = order == Self.last && pushed > 0 ? -pushed * Self.parallax * width : (CGFloat(order) - shown) * width
                let onScreen = abs(x) < width - 0.5
                let current = order == index
                page(route)
                    .offset(x: x)
                    .allowsHitTesting(current)
                    .accessibilityHidden(!current)
                    .environment(\.pageActive, current || onScreen)
                    .environment(\.pagePrefetch, !(current || onScreen))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .gesture(PagerPan(enabled: !composing && handing == nil, allows: allows, changed: follow, ended: settle))
        .accessibilityScrollAction { edge in
            if edge == .leading, index > 0 { workspace.select(Dock.pages[index - 1]) }
            if edge == .trailing, index < Self.last { workspace.select(Dock.pages[index + 1]) }
        }
        .overlay { chrome.offset(x: -pushed * Self.parallax * width) }
        .overlay {
            if let view = handing ?? ahead {
                ShotView(shot: view)
                    .ignoresSafeArea()
                    .shadow(color: pushed > 0 && pushed < 1 ? palette.panelShadow : .clear, radius: 12)
                    .offset(x: (1 - pushed) * width)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // 位移是 SwiftUI 逐帧插值的，图层上看不出在动：截图要等停稳再拍
        .debugSettling(drag != 0 || position != CGFloat(index))
        .onAppear {
            position = CGFloat(index)
            built = [workspace.root]
            prebuild()
        }
        .onChange(of: workspace.root) { _, root in slide(to: root) }
    }

    @ViewBuilder private func page(_ route: Route) -> some View {
        if built.contains(route) {
            // 推着的页各自铺满底色，不透出邻页
            HomePage(route: route).background(palette.desk)
        } else {
            palette.desk.ignoresSafeArea()
        }
    }

    /// Cue 页右边那一页的快照：停在 Cue 页、刚返回离开的那一页正是快照拍的那一页。
    private var forwardShot: UIView? {
        guard workspace.root == Dock.pages[Self.last], let forward = workspace.forward, shot.route == forward else { return nil }
        return shot.view
    }

    private func allows(_ direction: PagerPan.Direction) -> Bool {
        let index = Dock.order(workspace.root)
        switch direction {
        case .previous: return index > 0
        case .next: return index < Self.last || forwardShot != nil
        }
    }

    /// 跟手；那一侧没有页时越拖越沉（同系统滚动到头的阻尼）。
    private func follow(_ translation: CGFloat) {
        let index = Dock.order(workspace.root)
        let room = translation > 0 ? (index > 0) : (index < Self.last || forwardShot != nil)
        if room {
            drag = max(-width, min(width, translation))
        } else {
            let damped = (1 - 1 / (abs(translation) * 0.55 / max(width, 1) + 1)) * width
            drag = translation < 0 ? -damped : damped
        }
    }

    /// 松手：按甩出的方向估落点，过了半页就去那一页，否则回原处；弹簧接着手指的速度走。
    private func settle(velocity: CGFloat, commits: Bool) {
        let index = Dock.order(workspace.root)
        let projected = drag + velocity * 0.2
        var target = index
        if commits, projected > width / 2, velocity > -200, index > 0 { target = index - 1 }
        if commits, projected < -width / 2, velocity < 200, index < Self.last || forwardShot != nil { target = index + 1 }
        let remaining = CGFloat(index - target) * width - drag
        let spring = Animation.interpolatingSpring(
            duration: 0.3, bounce: 0, initialVelocity: abs(remaining) > 1 ? min(max(velocity / remaining, -20), 20) : 0)
        guard target <= Self.last else { return forward(spring) }
        withAnimation(spring) {
            position = CGFloat(target)
            drag = 0
            if target != index { workspace.select(Dock.pages[target]) }
        } completion: {
            prebuild()
        }
    }

    /// 拉到前进页松手：快照停到原处，再不带动画地推入真的页，它画上屏后收起快照、这一条回到 Cue 页（推入的页盖着）。
    private func forward(_ spring: Animation) {
        guard let view = forwardShot else { return }
        withAnimation(spring) {
            position = CGFloat(Self.last + 1)
            drag = 0
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                handing = view
                workspace.goForward()
            }
            Task {
                await NextFrame.drawn()
                withTransaction(still) {
                    position = CGFloat(Self.last)
                    handing = nil
                }
            }
        }
    }

    /// 去处换了（点底部那一排、深链、提示）而这一条还没挪过去：先建好一路要露出来的页，下一帧整条滑过去。
    private func slide(to root: Route) {
        let target = CGFloat(Dock.order(root))
        guard position != target, drag == 0 else { return }
        let from = Int(position.rounded()), to = Int(target)
        let missing = Dock.pages[min(from, to)...max(from, to)].filter { !built.contains($0) }
        built.formUnion(missing)
        guard !reduceMotion else {
            position = target
            return prebuild()
        }
        Task {
            if !missing.isEmpty { await NextFrame.wait() }
            guard Dock.order(workspace.root) == to else { return }
            withAnimation(Motion.dock) { position = target } completion: { prebuild() }
        }
    }

    /// 停稳后建好两边的邻页，下一次拖时它们已经在那里。
    private func prebuild() {
        let index = Dock.order(workspace.root)
        let neighbors = [index - 1, index + 1].filter { Dock.pages.indices.contains($0) }.map { Dock.pages[$0] }
        guard neighbors.contains(where: { !built.contains($0) }) else { return }
        Task {
            await NextFrame.drawn()
            guard drag == 0 else { return }
            built.formUnion(neighbors)
        }
    }
}

/// 根上四页的横拖（UIKit 的拖动手势，开始那一刻按状态给方向，同 Telegram 的文件夹切换）：
/// - 横向比纵向快、那一侧有页（`allows`）才开始；手指下面横着能滚的内容（看板的列、表格、附件条）还能往那边滚时让它先滚，滚到头再拖才翻页。
/// - 页里的滚动等它先判（横着翻页时列表不跟着竖着滚）；行上的轻扫（系统列表的、自绘的）它等它们先判：那一行在这个方向有动作时归行。
/// - 手指下面是正在输入的输入框时不开始。
struct PagerPan: UIGestureRecognizerRepresentable {
    enum Direction { case previous, next }

    let enabled: Bool
    let allows: (Direction) -> Bool
    let changed: (CGFloat) -> Void
    let ended: (_ velocity: CGFloat, _ commits: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = enabled
        context.coordinator.allows = allows
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: changed(pan.translation(in: pan.view).x)
        case .ended:
            changed(pan.translation(in: pan.view).x)
            ended(pan.velocity(in: pan.view).x, true)
        case .cancelled, .failed: ended(0, false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allows: (Direction) -> Bool = { _ in false }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            let motion = velocity == .zero ? pan.translation(in: view) : velocity
            guard abs(motion.x) > abs(motion.y) else { return false }
            let direction: Direction = motion.x < 0 ? .next : .previous
            return allows(direction) && !Self.yields(toward: direction, at: pan.location(in: view), in: view)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let view = recognizer.view, let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
            return scroll.isDescendant(of: view)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            guard other is UIPanGestureRecognizer, let view = recognizer.view, let owner = other.view, owner !== view, owner.isDescendant(of: view) else { return false }
            return (owner as? UIScrollView)?.panGestureRecognizer !== other
        }

        /// 手指下面有横着还能往这边滚的内容，或正在输入的输入框：让给它。
        private static func yields(toward direction: Direction, at point: CGPoint, in root: UIView) -> Bool {
            var view = root.hitTest(point, with: nil)
            while let current = view, current !== root {
                if current.isFirstResponder, current is UITextInput { return true }
                if let scroll = current as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 {
                    let inset = scroll.adjustedContentInset, x = scroll.contentOffset.x
                    let room = direction == .previous ? x > -inset.left + 1 : x < scroll.contentSize.width - scroll.bounds.width + inset.right - 1
                    if room { return true }
                }
                view = current.superview
            }
            return false
        }
    }
}

/// 推入的页离开前（返回、被别的页盖住）拍下的整栈快照（连同顶栏），只留最近一张：Cue 页上左滑前进时先拿它跟手（`HomePager`）。
/// 快照是渲染服务里那一份的引用，拍一张不重画、不占主线程。
@Observable
final class LeaveShot {
    private(set) var route: Route?
    private(set) var view: UIView?

    fileprivate func take(_ route: Route, from controller: UIViewController) {
        guard let stack = controller.navigationController?.view, let view = stack.snapshotView(afterScreenUpdates: false) else { return }
        self.route = route
        self.view = view
    }
}

extension View {
    /// 推入的页挂上它：离开前把整栈拍进 `shot`。
    func leaveShot(_ route: Route, into shot: LeaveShot) -> some View {
        background { LeaveProbe { shot.take(route, from: $0) } }
    }
}

/// 推入页里一个不占地方的子控制器：页要离开时（`viewWillDisappear`，转场开始之前、页还原样在屏上）报一声。
private struct LeaveProbe: UIViewControllerRepresentable {
    let leaving: (UIViewController) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) { probe.leaving = leaving }

    final class Probe: UIViewController {
        var leaving: (UIViewController) -> Void = { _ in }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            leaving(self)
        }
    }
}

/// 把快照挂进页里（左上对齐，原尺寸）。
private struct ShotView: UIViewRepresentable {
    let shot: UIView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard shot.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        shot.frame.origin = .zero
        host.addSubview(shot)
    }
}
#endif
