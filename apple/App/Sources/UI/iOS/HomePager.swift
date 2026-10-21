#if os(iOS)
import SwiftUI
import UIKit

/// 窄屏根上的四页按底部那一排的顺序（`Dock.pages`）横着排成一条：左右滑跟手切页，松手按甩出的方向停到一页；点底部那一排换去处时整条滑过去。
/// 当前页只有 `Workspace.root` 一份：松手、点按都经 `select`；这一条此刻挪到哪（`PagerMotion`）只是跟着它走的位置。
/// Cue 在最右，它右边是刚返回离开的那一页（`Workspace.forward`）：手指左滑把它拉回来。跟手的是离开前拍的快照（`LeaveShot`，同 Safari 的前进），
/// 同系统推入一样盖着 Cue 页滑进来、Cue 页与底部那一排慢慢退；松手推入真的页（不带动画），它画上屏后才收起快照。
/// 每帧只改位移：页在条上的位置是定的，拖动与弹簧只挪整条（与前进时的 Cue 页、快照、底部那一排）的偏移，偏移只有几个小视图读（`Shift`），
/// 这一页的视图体与四页都不跟着重算。
/// 先排后动：页建过就一直留着（回访不重建、滚动位置还在）。打开 App 后安静一阵（`quiet`）再一页一页地建，离当前页近的先建；
/// 滑完停稳时邻页还没建（刚打开就连着滑）才当场建。不在屏上的页透明（不画）、暂停订阅与实时状态（`pageActive`），没读过的先读一份（`pagePrefetch`）。
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
    @State private var motion = PagerMotion()
    @State private var built: Set<Route> = [Route.first]
    /// 正在滑的页（跟手、松手后的弹簧、点按滑过去的一路）：只有它们与当前页画、订阅。
    @State private var moving: Set<Route> = []
    /// 第几次滑：上一次的弹簧做完时已经开始了新的一次，就不收。
    @State private var turn = 0
    /// 前进松手后推入真的页，它画上屏之前快照还留着。
    @State private var handing: UIView?
    /// 根在屏上（没被推入的页盖住）。
    @State private var exposed = false

    private static var last: Int { Dock.pages.count - 1 }
    /// 前进时 Cue 页退开的比例（同系统推入时下面那一页）。
    private static var parallax: CGFloat { 0.3 }
    /// 打开 App 后先等这么久再建别的页：首屏、紧接着的滚动与输入不和它挤（同 Mac 启动后的预热）。
    private static var quiet: Duration { .seconds(2) }

    var body: some View {
        let index = Dock.order(workspace.root)
        let ahead = handing ?? forwardShot
        let forward = ahead != nil
        ZStack(alignment: .topLeading) {
            ForEach(Dock.pages, id: \.self) { route in
                let order = Dock.order(route)
                let live = order == index || moving.contains(route)
                page(route)
                    // 前进时整条停在 Cue，Cue 页自己只退一截
                    .modifier(Shift(motion: motion) { order == Self.last && forward ? -$0.pushed * Self.parallax * $0.width : 0 })
                    .offset(x: CGFloat(order) * motion.width)
                    .opacity(live ? 1 : 0)
                    .allowsHitTesting(order == index)
                    .accessibilityHidden(order != index)
                    .environment(\.pageActive, live)
                    .environment(\.pagePrefetch, !live)
            }
        }
        .modifier(Shift(motion: motion) { -$0.strip(forward: forward) * $0.width })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { motion.width = $0 }
        .gesture(PagerPan(enabled: !composing && handing == nil, changed: follow, ended: settle))
        .accessibilityScrollAction { edge in
            if edge == .leading, index > 0 { workspace.select(Dock.pages[index - 1]) }
            if edge == .trailing, index < Self.last { workspace.select(Dock.pages[index + 1]) }
        }
        .overlay { chrome.modifier(Shift(motion: motion) { forward ? -$0.pushed * Self.parallax * $0.width : 0 }) }
        .overlay {
            if let ahead { ForwardPage(shot: ahead, motion: motion).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .onAppear {
            motion.position = CGFloat(index)
            built.insert(workspace.root)
            exposed = true
        }
        .onDisappear { exposed = false }
        // 安静一阵后建下一页还没建的（离当前页近的先建），建完一页再等一阵；又动了、被盖住了就重新等
        .task(id: Idle(root: workspace.root, built: built.count, resting: exposed && moving.isEmpty)) {
            guard exposed, moving.isEmpty, let next = unbuilt, (try? await Task.sleep(for: Self.quiet)) != nil else { return }
            built.insert(next)
        }
        // 位移是 SwiftUI 逐帧插值的，图层上看不出在动：截图要等停稳再拍
        .debugSettling(!moving.isEmpty)
        .onChange(of: workspace.root) { _, root in slide(to: root) }
    }

    private struct Idle: Equatable {
        let root: Route
        let built: Int
        let resting: Bool
    }

    @ViewBuilder private func page(_ route: Route) -> some View {
        if built.contains(route) {
            // 滑着的页各自铺满底色，不透出邻页
            HomePage(route: route).background(palette.desk)
        } else {
            palette.desk.ignoresSafeArea()
        }
    }

    /// 还没建的页里离当前页最近的。
    private var unbuilt: Route? {
        let index = Dock.order(workspace.root)
        return Dock.pages.filter { !built.contains($0) }.min { abs(Dock.order($0) - index) < abs(Dock.order($1) - index) }
    }

    /// Cue 页右边那一页的快照：停在 Cue 页、刚返回离开的那一页正是快照拍的那一页。
    private var forwardShot: UIView? {
        guard workspace.root == Dock.pages[Self.last], let forward = workspace.forward, shot.route == forward else { return nil }
        return shot.view
    }

    private func neighbor(_ direction: PagerPan.Direction) -> Route? {
        let index = Dock.order(workspace.root) + (direction == .previous ? -1 : 1)
        return Dock.pages.indices.contains(index) ? Dock.pages[index] : nil
    }

    private func allows(_ direction: PagerPan.Direction) -> Bool {
        neighbor(direction) != nil || direction == .next && forwardShot != nil
    }

    /// 跟手；那一侧没有页时越拖越沉（同系统滚动到头的阻尼）。露出来的邻页还没建（刚打开就拖）时当场建。
    private func follow(_ translation: CGFloat) {
        let direction: PagerPan.Direction = translation > 0 ? .previous : .next
        if let next = neighbor(direction), !moving.contains(next) {
            built.insert(next)
            moving.formUnion([workspace.root, next])
        }
        let width = max(motion.width, 1)
        if allows(direction) {
            motion.drag = max(-width, min(width, translation))
        } else {
            let damped = (1 - 1 / (abs(translation) * 0.55 / width + 1)) * width
            motion.drag = translation < 0 ? -damped : damped
        }
    }

    /// 松手：按甩出的方向估落点，过了半页就去那一页，否则回原处；弹簧接着手指的速度走。
    private func settle(velocity: CGFloat, commits: Bool) {
        let index = Dock.order(workspace.root)
        let drag = motion.drag, width = motion.width
        let projected = drag + velocity * 0.2
        var target = index
        if commits, projected > width / 2, velocity > -200, allows(.previous) { target = index - 1 }
        if commits, projected < -width / 2, velocity < 200, allows(.next) { target = index + 1 }
        let remaining = CGFloat(index - target) * width - drag
        let spring = Animation.interpolatingSpring(
            duration: 0.3, bounce: 0, initialVelocity: abs(remaining) > 1 ? min(max(velocity / remaining, -20), 20) : 0)
        guard target <= Self.last else { return forward(spring) }
        turn += 1
        let current = turn
        withAnimation(spring) {
            motion.position = CGFloat(target)
            motion.drag = 0
            if target != index { workspace.select(Dock.pages[target]) }
        } completion: {
            rest(after: current)
        }
    }

    /// 拉到前进页松手：快照停到原处，再不带动画地推入真的页，它画上屏后收起快照、这一条回到 Cue 页（推入的页盖着）。
    private func forward(_ spring: Animation) {
        guard let view = forwardShot else { return }
        withAnimation(spring) {
            motion.position = CGFloat(Self.last + 1)
            motion.drag = 0
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
                    motion.position = CGFloat(Self.last)
                    handing = nil
                }
            }
        }
    }

    /// 去处换了（点底部那一排、深链、提示）而这一条还没挪过去：先建好一路要露出来的页，下一帧整条滑过去。
    private func slide(to root: Route) {
        let target = CGFloat(Dock.order(root))
        guard motion.position != target, motion.drag == 0 else { return }
        let from = Int(motion.position.rounded()), to = Int(target)
        let span = Set(Dock.pages[min(from, to)...max(from, to)])
        let missing = !span.isSubset(of: built)
        built.formUnion(span)
        turn += 1
        let current = turn
        guard !reduceMotion else {
            motion.position = target
            return rest(after: current)
        }
        Task {
            if missing { await NextFrame.wait() }
            guard Dock.order(workspace.root) == to, current == turn else { return }
            moving.formUnion(span)
            withAnimation(Motion.dock) { motion.position = target } completion: { rest(after: current) }
        }
    }

    /// 停稳：滑过的页不再画；邻页还没建（刚打开就连着滑）时接着建，下一次拖时它已经在那里。
    private func rest(after current: Int) {
        guard current == turn, motion.drag == 0 else { return }
        moving = []
        let neighbors = Set([neighbor(.previous), neighbor(.next)].compactMap(\.self))
        guard !neighbors.isSubset(of: built) else { return }
        Task {
            await NextFrame.drawn()
            guard moving.isEmpty, workspace.path.isEmpty else { return }
            built.formUnion(neighbors)
        }
    }
}

/// 这一条此刻挪到哪：只有挪位置的几个小视图读它（`Shift`），拖动、弹簧每帧改它时不重算整页。
@Observable
private final class PagerMotion {
    /// 停在第几页（Cue 右边的前进页是最后一页加一）。
    var position = CGFloat(Dock.order(Route.first))
    /// 手指这次拖了多远（点）。
    var drag: CGFloat = 0
    var width: CGFloat = 0

    /// 此刻停在第几页的连续值。
    var shown: CGFloat { position - (width > 0 ? drag / width : 0) }
    /// 拉出前进页的进度，0…1。
    var pushed: CGFloat { min(max(shown - CGFloat(Dock.pages.count - 1), 0), 1) }

    /// 整条挪到第几页：有前进页时整条停在 Cue（前进只挪快照与 Cue 页）；没有时照常越拖越沉。
    func strip(forward: Bool) -> CGFloat { forward ? min(shown, CGFloat(Dock.pages.count - 1)) : shown }
}

/// 按此刻的位置平移：读 `PagerMotion` 的只有这一层，拖动时只重算它。
private struct Shift: ViewModifier {
    let motion: PagerMotion
    let x: (PagerMotion) -> CGFloat

    func body(content: Content) -> some View { content.offset(x: x(motion)) }
}

/// 拉出来的前进页：快照盖着 Cue 页从右边滑进来，边上一道阴影（同系统推入）；没拉出来时什么都不挂。
private struct ForwardPage: View {
    let shot: UIView
    let motion: PagerMotion
    @Environment(\.palette) private var palette

    var body: some View {
        let pushed = motion.pushed
        if pushed > 0 {
            ShotView(shot: shot)
                .ignoresSafeArea()
                .shadow(color: pushed < 1 ? palette.panelShadow : .clear, radius: 12)
                .offset(x: (1 - pushed) * motion.width)
        }
    }
}

/// 根上四页的横拖（UIKit 的拖动手势，开始那一刻按状态给方向，同 Telegram 的文件夹切换）：
/// - 横向比纵向快才开始；手指下面横着能滚的内容（看板的列、表格、附件条）还能往那边滚时让它先滚，滚到头再拖才翻页。
///   那一侧没有页（最左的项目、没有可前进的 Cue）也接，只是越拖越沉（同系统滚动到头）：不接的话这一拖落到手指下面的行上，松手就点开了它。
/// - 页里的滚动等它先判（横着翻页时列表不跟着竖着滚）；行上的轻扫先判（`rowSwipes` 只认慢拖、那个方向有动作），行不要的才归它。
/// - 手指下面是正在输入的输入框时不开始。
struct PagerPan: UIGestureRecognizerRepresentable {
    enum Direction { case previous, next }

    let enabled: Bool
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
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            let motion = velocity == .zero ? pan.translation(in: view) : velocity
            guard abs(motion.x) > abs(motion.y) else { return false }
            return !Self.yields(toward: motion.x < 0 ? .next : .previous, at: pan.location(in: view), in: view)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let view = recognizer.view, let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
            return scroll.isDescendant(of: view)
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
/// 只有推在 Cue 页上的页挂它（别的根上没有前进）：拍一张要等渲染服务交出那一份，约几毫秒。
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
