#if os(iOS)
import SwiftUI
import UIKit

/// 根上三页的容器：三页按 `Dock.pages` 的顺序并排在一条上（`strip`），切页只平移这一条（Cue 页前进时另有自己的退开）；页都铺满容器（安全区、键盘照常由 UIKit 给）。
/// 页与条只摆 `bounds` 与 `center`，不碰 `frame`：带平移的视图设 `frame` 会把那一刻的平移折进 `center`，之后平移一变页就带着一段残留位移
/// （曾经每次排版都这样折一下：停在旧页再一下闪成新页、邻页叠在当前页上、Cue 页歪着露出旁边一角）。
/// 条的位置只有一份（`offset`），每次挪都经 `apply` 同时交给 `PagerMotion`（底部那一排的滴与换形读它）。
/// 各页的托管控制器建过就留着（回访不重建、滚动位置还在），挂不挂在窗口上另说：
/// - 当前页一直挂着；滑动中露出来的页（`moving`）挂着、画着、订阅着；
/// - 两边的邻页停稳后挂上但藏着（下一次拖时现成），不订阅（`pageActive` 为假，没读过的先读一份 `pagePrefetch`）；
/// - 推入的页盖住根（转场做完）时只留当前页挂着：返回时导航栈把根重新挂回窗口，挂着几页就要重排几页。回到根上安静一阵再把邻页挂回去。
/// 还没建的页在打开 App 后安静一阵（`buildDelay`）再一页一页地建，离当前页近的先建；拖的那一下邻页还没有才当场建。
final class PagerController: UIViewController {
    struct Input {
        let environment: EnvironmentValues
        let root: Route
        let forward: UIView?
        let composing: Bool
        let reduceMotion: Bool
    }

    private let workspace: Workspace
    private let motion: PagerMotion
    private var input: Input?
    private var pages: [Route: Page] = [:]
    private let strip = UIView()
    /// 正在滑的页：画、订阅。
    private var moving: Set<Route> = []
    /// 条要停的那一页：跟着 `Workspace.root`，只在松手时先于它改（先把弹簧交出去再 `select`）；`update` 见到两者不同就是去处从别处换了，滑过去。
    private var resting = Route.first
    /// 条的平移（点）：停在第 i 页是 -i×宽；拉出前进页时越过最后一页。
    private var offset: CGFloat = 0
    private var dragStart: CGFloat = 0
    /// 第几次动：弹簧做完时已经开始了新的一次，就不收尾。
    private var turn = 0
    /// 前进松手后推入真的页，它画上屏之前快照还留着。
    private var handing = false
    private var covered = false
    private var idle: Task<Void, Never>?
    private let pan = UIPanGestureRecognizer()
    private let arbiter = PagerArbiter()

    private static var last: Int { Dock.pages.count - 1 }
    /// 前进时 Cue 页退开的比例（同系统推入时下面那一页）。
    static let parallax: CGFloat = 0.3
    /// 打开 App 后先等这么久再建别的页：首屏、紧接着的滚动与输入不和它挤（同 Mac 启动后的预热）。
    private static let buildDelay: Duration = .seconds(2)
    /// 返回到根上后等这么久再把邻页挂回去：不压在返回转场刚停的那几帧上。
    private static let attachDelay: Duration = .milliseconds(500)

    init(workspace: Workspace, motion: PagerMotion) {
        self.workspace = workspace
        self.motion = motion
        resting = workspace.root
        super.init(nibName: nil, bundle: nil)
        motion.move(to: CGFloat(Dock.order(resting)), pushed: 0)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = PagerView()
        container.scroll = { [weak self] edge in self?.scroll(toward: edge) ?? false }
        container.addSubview(strip)
        view = container
        pan.maximumNumberOfTouches = 1
        pan.delegate = arbiter
        pan.addTarget(self, action: #selector(panned))
        view.addGestureRecognizer(pan)
    }

    // MARK: 输入

    func update(_ input: Input) {
        let first = self.input == nil
        self.input = input
        pan.isEnabled = !input.composing && !handing
        if first { build(resting) }
        for route in pages.keys { refresh(route) }
        if !handing, motion.shot !== input.forward { motion.shot = input.forward }
        if input.root != resting { slide(to: input.root) }
    }

    private var width: CGFloat { view.bounds.width }

    /// 在屏上的页：停着的那页与正在滑的页。
    private var live: Set<Route> { moving.union([resting]) }

    /// 一页的内容：环境整份转过来，再标上它此刻在不在屏上。
    private func refresh(_ route: Route) {
        guard let input, let page = pages[route] else { return }
        let live = live.contains(route)
        page.host.rootView = AnyView(
            HomePage(route: route).background(input.environment.palette.desk)
                .environment(\.pageActive, live).environment(\.pagePrefetch, !live)
                .environment(\.self, input.environment))
        page.slot.isHidden = !live
    }

    /// 条横跨三页（点得到哪页，条的 `bounds` 就要盖到哪页），各页在条上的位置只随宽变；平移不在这里，排版多少次都不挪页。宽变了（转屏、分屏）停回当前页。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        strip.bounds = CGRect(x: 0, y: 0, width: size.width * CGFloat(Dock.pages.count), height: size.height)
        strip.center = CGPoint(x: strip.bounds.midX, y: size.height / 2)
        for (route, page) in pages { place(page, at: route) }
        guard motion.width != size.width else { return }
        motion.width = size.width
        stopAnimations()
        offset = -CGFloat(Dock.order(resting)) * size.width
        apply(offset)
    }

    private func place(_ page: Page, at route: Route) {
        let size = view.bounds.size
        page.slot.bounds = CGRect(origin: .zero, size: size)
        page.slot.center = CGPoint(x: (CGFloat(Dock.order(route)) + 0.5) * size.width, y: size.height / 2)
    }

    // MARK: 建页、挂页

    private func build(_ route: Route) {
        guard pages[route] == nil else { return attach(route) }
        let page = Page()
        pages[route] = page
        addChild(page.host)
        attach(route)
        page.host.didMove(toParent: self)
        refresh(route)
        // 先排后动：建好就排一次，第一次露出来时不在跟手的那一帧里排
        page.slot.layoutIfNeeded()
    }

    private func attach(_ route: Route) {
        guard let page = pages[route], page.slot.superview !== strip else { return }
        place(page, at: route)
        strip.addSubview(page.slot)
    }

    private func detach(_ route: Route) {
        pages[route]?.slot.removeFromSuperview()
    }

    private func neighbors(of route: Route) -> [Route] {
        let index = Dock.order(route)
        return [index - 1, index + 1].filter { Dock.pages.indices.contains($0) }.map { Dock.pages[$0] }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        covered = false
        settleDown()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        covered = true
        idle?.cancel()
        for route in pages.keys where route != resting { detach(route) }
    }

    /// 安静下来以后一步一步补齐：先把建过的邻页挂回去，再由近及远建还没建的页；每一步之间再等一阵，又动了就重新等。
    private func settleDown() {
        idle?.cancel()
        let detached = neighbors(of: resting).filter { pages[$0] != nil && pages[$0]?.slot.superview !== strip }
        let index = Dock.order(resting)
        let unbuilt = Dock.pages.filter { pages[$0] == nil }.min { abs(Dock.order($0) - index) < abs(Dock.order($1) - index) }
        guard !covered, let next = detached.first ?? unbuilt else { return }
        let delay = detached.isEmpty ? Self.buildDelay : Self.attachDelay
        idle = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, !self.covered, !self.motion.busy else { return }
            self.build(next)
            self.settleDown()
        }
    }

    // MARK: 摆位置

    private var cuePage: UIView? { pages[Dock.pages[Self.last]]?.slot }

    /// 按条的平移摆好：条、前进时退开的 Cue 页，并告诉 SwiftUI 那一层（底部那一排、快照）条在哪。
    private func apply(_ offset: CGFloat) {
        let w = max(width, 1), stop = -CGFloat(Self.last) * w
        let forward = motion.shot != nil
        let pushed = forward ? min(max((stop - offset) / w, 0), 1) : 0
        let position = -(forward ? max(offset, stop) : offset) / w
        strip.transform = CGAffineTransform(translationX: -position * w, y: 0)
        cuePage?.transform = CGAffineTransform(translationX: -pushed * Self.parallax * w, y: 0)
        motion.move(to: position, pushed: pushed)
    }

    /// 条此刻的平移（弹簧在半路时从图层读：条在哪，拉出前进页时是 Cue 页退开了多少）。
    private func presentedOffset() -> CGFloat {
        guard let x = strip.layer.presentation()?.affineTransform().tx else { return offset }
        let back = cuePage?.layer.presentation()?.affineTransform().tx ?? 0
        return back < 0 ? x + back / Self.parallax : x
    }

    private func stopAnimations() {
        strip.layer.removeAllAnimations()
        cuePage?.layer.removeAllAnimations()
    }

    /// 停在哪页、哪几页在滑只经这里改：在屏上的页（`live`）变了的那几页重新标上可见与订阅。
    /// 停的页换了也算（减弱动态效果时直接到位，没有页在滑，只有停的页换了）。
    private func show(resting: Route? = nil, moving: Set<Route>) {
        let before = live
        if let resting { self.resting = resting }
        self.moving = moving
        for route in before.symmetricDifference(live) { refresh(route) }
        motion.busy = !moving.isEmpty || pan.state == .began || pan.state == .changed
    }

    // MARK: 跟手

    private func allows(_ direction: PagerArbiter.Direction) -> Bool {
        let index = Dock.order(resting)
        return direction == .previous ? index > 0 : index < Self.last || input?.forward != nil
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).x
        switch pan.state {
        case .began:
            idle?.cancel()
            turn += 1
            if motion.busy {
                offset = presentedOffset()
                stopAnimations()
            }
            dragStart = offset
            motion.busy = true
            follow(translation)
        case .changed: follow(translation)
        case .ended: settle(velocity: pan.velocity(in: view).x, commits: true)
        default: settle(velocity: 0, commits: false)
        }
    }

    /// 跟手；那一侧没有页时越拖越沉（同系统滚动到头的阻尼）。露出来的邻页现成就挂上、画上，还没建时当场建。
    private func follow(_ translation: CGFloat) {
        let direction: PagerArbiter.Direction = translation > 0 ? .previous : .next
        let index = Dock.order(resting) + (direction == .previous ? -1 : 1)
        if Dock.pages.indices.contains(index), !moving.contains(Dock.pages[index]) {
            build(Dock.pages[index])
            show(moving: moving.union([resting, Dock.pages[index]]))
        }
        let w = max(width, 1), base = -CGFloat(Dock.order(resting)) * w
        var target = dragStart + translation
        if !allows(direction) {
            let over = target - base
            target = base + (over < 0 ? -1 : 1) * (1 - 1 / (abs(over) * 0.55 / w + 1)) * w
        }
        offset = min(max(target, base - w), base + w)
        apply(offset)
    }

    /// 松手：按甩出的方向估落点，过了半页就去那一页，否则回原处；弹簧接着手指的速度走（Core Animation 播）。
    private func settle(velocity: CGFloat, commits: Bool) {
        let index = Dock.order(resting), w = max(width, 1)
        let moved = offset + CGFloat(index) * w, projected = moved + velocity * 0.2
        var target = index
        if commits, projected > w / 2, velocity > -200, allows(.previous) { target = index - 1 }
        if commits, projected < -w / 2, velocity < 200, allows(.next) { target = index + 1 }
        let turned = target != index && target <= Self.last
        if turned { show(resting: Dock.pages[target], moving: moving) }
        animate(to: -CGFloat(target) * w, velocity: velocity) { [weak self] in
            if target > Self.last { self?.commitForward() } else { self?.rest() }
        }
        guard turned else { return }
        // 换去处是一次 SwiftUI 更新（页里订阅、底部那一排的选中），主线程要忙一两帧：先把弹簧交给渲染服务，页在这几帧里照样滑
        CATransaction.flush()
        workspace.select(resting)
    }

    /// 切页只有这一条弹簧：松手、点按、深链都经它；条的图层与 SwiftUI 那一层（底部那一排、前进页）同一条、同一个初速度。
    private func animate(to target: CGFloat, velocity: CGFloat = 0, done: @escaping () -> Void) {
        turn += 1
        let current = turn
        let distance = target - offset
        let initial = abs(distance) > 1 ? min(max(velocity / distance, -20), 20) : 0
        offset = target
        withAnimation(.interpolatingSpring(duration: Motion.dockDuration, bounce: 0, initialVelocity: initial)) {
            UIView.animate(springDuration: Motion.dockDuration, bounce: 0, initialSpringVelocity: initial, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.apply(target)
            } completion: { [weak self] _ in
                guard let self, current == self.turn else { return }
                done()
            }
        }
    }

    /// 停稳：滑过的页藏起来、不订阅；邻页还没挂上（刚打开就连着滑）时接着挂、接着建。
    private func rest() {
        show(moving: [])
        for route in neighbors(of: resting) where pages[route] != nil { attach(route) }
        settleDown()
    }

    /// 拉到前进页松手：快照停在原处，不带动画地推入真的页，它画上屏后收起快照、这一条回到 Cue 页（推入的页盖着）。
    private func commitForward() {
        handing = true
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { workspace.goForward() }
        Task { [weak self] in
            await NextFrame.drawn()
            guard let self else { return }
            self.handing = false
            self.offset = -CGFloat(Self.last) * max(self.width, 1)
            withTransaction(still) {
                self.motion.shot = self.input?.forward
                self.apply(self.offset)
            }
            self.motion.busy = false
            self.pan.isEnabled = !(self.input?.composing ?? false)
        }
    }

    // MARK: 点按换去处

    /// 去处换了（点底部那一排、深链、提示）而条还没挪过去：先建好一路要露出来的页，下一帧整条从此刻的位置滑过去（弹簧半路再点也是接着走）；减弱动态效果时直接换。
    private func slide(to root: Route) {
        let from = Dock.order(resting), to = Dock.order(root)
        let span = Set(Dock.pages[min(from, to)...max(from, to)])
        let missing = span.contains { pages[$0] == nil }
        for route in span { build(route) }
        idle?.cancel()
        guard !(input?.reduceMotion ?? false), view.window != nil else {
            stopAnimations()
            show(resting: root, moving: [])
            offset = -CGFloat(to) * width
            apply(offset)
            return rest()
        }
        show(resting: root, moving: moving.union(span))
        Task { [weak self] in
            if missing { await NextFrame.wait() }
            guard let self, self.resting == root else { return }
            self.animate(to: -CGFloat(to) * self.width) { [weak self] in self?.rest() }
        }
    }

    /// 读屏的三指左右滑：换到那一边的页。
    private func scroll(toward edge: UIAccessibilityScrollDirection) -> Bool {
        let index = Dock.order(resting) + (edge == .right ? -1 : edge == .left ? 1 : 0)
        guard index != Dock.order(resting), Dock.pages.indices.contains(index) else { return false }
        workspace.select(Dock.pages[index])
        return true
    }
}

/// 一页：托管控制器套在一层视图里（Cue 页前进时平移的就是它）。
private final class Page {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    let slot = UIView()

    init() {
        host.view.backgroundColor = .clear
        host.view.frame = slot.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        slot.addSubview(host.view)
    }
}

/// 容器的视图：读屏的三指滑交给容器。
private final class PagerView: UIView {
    var scroll: (UIAccessibilityScrollDirection) -> Bool = { _ in false }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool { scroll(direction) }
}
#endif
