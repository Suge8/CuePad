#if os(iOS)
import SwiftUI
import UIKit

/// 窄屏的三个 tab 并排在一条上（`strip`，按 `Dock.tabs` 的顺序），每个 tab 一页、页里是它自己的导航栈（`DockStack`）：切 tab 只平移这一条
/// （Cue 页前进时另有自己的退开）；页都铺满容器（安全区、键盘照常由 UIKit 给）。
/// 页与条只摆 `bounds` 与 `center`，不碰 `frame`：带平移的视图设 `frame` 会把那一刻的平移折进 `center`，之后平移一变页就带着一段残留位移
/// （曾经每次排版都这样折一下：停在旧页再一下闪成新页、邻页叠在当前页上、Cue 页歪着露出旁边一角）。
/// 条的位置只有一份（`offset`），每次挪都经 `apply` 同时交给 `DockMotion`（底部那一排的选中与换形读它）。
/// 选中哪个 tab 只有 `Workspace.root` 一份：条直接观察它、跟着它的变化滑（`updateProperties`），手势松手、读屏翻页是请它换（`Workspace.tapSoon`），不另记一份；
/// SwiftUI 只把环境交过来（`update`），换 tab 不经它、三页的内容不跟着整份重设。
/// 各页的托管控制器建过就一直挂在条上（回访不重建、滚动位置与推入的页都在），不在屏上的藏着、不订阅（`pageActive` 为假，没读过的先读一份 `pagePrefetch`）；
/// 滑动中露出来的页（`moving`）画着、订阅着。还没建的页在打开 App 后安静一阵（`buildDelay`）再一页一页地建，离当前页近的先建；拖的那一下邻页还没有才当场建。
final class PagerController: UIViewController {
    private let workspace: Workspace
    private let motion: DockMotion
    private let shot: LeaveShot
    /// 转给每一页的环境（`update`）；第一次交来时建当前页。
    private var environment: EnvironmentValues?
    /// 条上一次跟到的 root：只跟它的变化走，松手时条先停到了新页、root 还没跟上的那一下不算换了 tab，不把条拉回去。
    private var followed: Route
    private var pages: [Route: Page] = [:]
    private let strip = UIView()
    /// 正在滑的页：画、订阅。
    private var moving: Set<Route> = []
    /// 条停在哪一页：跟着 `Workspace.root` 的变化，只在松手时先于它改（先把弹簧交出去再请 root 跟上）。
    private var resting: Route { didSet { setNeedsUpdateProperties() } }
    /// 条的平移（点）：停在第 i 页是 -i×宽；拉出前进页时越过最后一页。
    private var offset: CGFloat = 0
    private var dragStart: CGFloat = 0
    /// 第几次动：弹簧做完时已经开始了新的一次，就不收尾。
    private var turn = 0
    /// 前进松手后推入真的页，它画上屏之前快照还留着。
    private var handing = false { didSet { setNeedsUpdateProperties() } }
    private var idle: Task<Void, Never>?
    private let pan = UIPanGestureRecognizer()
    private let arbiter = PagerArbiter()

    private static var last: Int { Dock.tabs.count - 1 }
    /// 前进时 Cue 页退开的比例（同系统推入时下面那一页）。
    private static let parallax: CGFloat = 0.3
    /// 打开 App 后先等这么久再建别的页：首屏、紧接着的滚动与输入不和它挤（同 Mac 启动后的预热）。
    private static let buildDelay: Duration = .seconds(2)

    init(workspace: Workspace, motion: DockMotion, shot: LeaveShot) {
        self.workspace = workspace
        self.motion = motion
        self.shot = shot
        resting = workspace.root
        followed = workspace.root
        super.init(nibName: nil, bundle: nil)
        motion.move(to: CGFloat(Dock.order(resting)), tab: Dock.order(resting), pushed: 0)
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

    /// 直接读 `Workspace`、`DockMotion` 与 `LeaveShot`（UIKit 自动跟踪这里读到的 Observable，变了再调一次），不经 SwiftUI 转一道：
    /// - 只在 tab 的根页上接横拖：推入了页时横拖归导航栈的返回；Cue 页的输入框有焦点时不接（选字、挪光标都是横着拖），前进松手到真的页画上屏之间也不接。
    /// - root 换了就滑过去，换了 tab 就忘了前进（`LeaveShot`）、切走的页交出键盘（它留在条上、藏着，输入框不交出焦点的话字还打进看不见的页里；要去的页这时可能正接过焦点，如"对 Cue 说"）；
    ///   滑动排到下一轮，它读写的 `DockMotion` 不记成这里的依赖。
    /// - 拉得出来的前进页只在 Cue 页上。
    override func updateProperties() {
        super.updateProperties()
        pan.isEnabled = !motion.composing && !handing && workspace[stack: resting].isEmpty
        let root = workspace.root
        if root != followed {
            followed = root
            shot.forget()
            for (tab, page) in pages where tab != root { page.slot.endEditing(true) }
            if root != resting { Task { self.slide(to: root) } }
        }
        let forward = root == .cue ? shot.view : nil
        if !handing, motion.shot !== forward { motion.shot = forward }
    }

    func update(_ environment: EnvironmentValues) {
        let first = self.environment == nil
        self.environment = environment
        if first { build(resting) }
        for route in pages.keys { refresh(route) }
    }

    private var width: CGFloat { view.bounds.width }

    /// 在屏上的页：停着的那页与正在滑的页。
    private var live: Set<Route> { moving.union([resting]) }

    /// 一页的内容：环境整份转过来，再标上它此刻在不在屏上。
    private func refresh(_ route: Route) {
        guard let environment, let page = pages[route] else { return }
        let live = live.contains(route)
        page.host.rootView = AnyView(
            DockStack(tab: route, active: live, shot: route == .cue ? shot : nil)
                .background(environment.palette.desk)
                .environment(\.self, environment))
        page.slot.isHidden = !live
    }

    /// 条横跨三页（点得到哪页，条的 `bounds` 就要盖到哪页），各页在条上的位置只随宽变；平移不在这里，排版多少次都不挪页。宽变了（转屏、分屏）停回当前页。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        strip.bounds = CGRect(x: 0, y: 0, width: size.width * CGFloat(Dock.tabs.count), height: size.height)
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

    // MARK: 建页

    private func build(_ route: Route) {
        guard pages[route] == nil else { return }
        let page = Page()
        pages[route] = page
        addChild(page.host)
        place(page, at: route)
        strip.addSubview(page.slot)
        page.host.didMove(toParent: self)
        refresh(route)
        // 先排后动：建好就排一次，第一次露出来时不在跟手的那一帧里排
        page.slot.layoutIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        buildLater()
    }

    /// 安静下来以后由近及远一页一页建还没建的页；每一页之间再等一阵，又动了就重新等。
    private func buildLater() {
        idle?.cancel()
        let index = Dock.order(resting)
        guard view.window != nil,
              let next = Dock.tabs.filter({ pages[$0] == nil }).min(by: { abs(Dock.order($0) - index) < abs(Dock.order($1) - index) })
        else { return }
        idle = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.buildDelay)) != nil, let self, self.view.window != nil, !self.motion.busy else { return }
            self.build(next)
            self.buildLater()
        }
    }

    // MARK: 摆位置

    private var cuePage: UIView? { pages[.cue]?.slot }

    private var dragging: Bool { pan.state == .began || pan.state == .changed }

    /// 按条的平移摆好：条、前进时退开的 Cue 页，并告诉 SwiftUI 那一层（底部那一排、快照）条在哪。
    /// 选中的格子拖动时跟着条（过半换格），松手、点按时直接是要去的那一格：条从 Cue 滑到项目不在半路选一下进展。
    private func apply(_ offset: CGFloat) {
        let w = max(width, 1), stop = -CGFloat(Self.last) * w
        let forward = motion.shot != nil
        let pushed = forward ? min(max((stop - offset) / w, 0), 1) : 0
        let position = -(forward ? max(offset, stop) : offset) / w
        strip.transform = CGAffineTransform(translationX: -position * w, y: 0)
        cuePage?.transform = CGAffineTransform(translationX: -pushed * Self.parallax * w, y: 0)
        motion.move(to: position, tab: dragging ? Int(position.rounded()) : Dock.order(resting), pushed: pushed)
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
        motion.busy = !moving.isEmpty || dragging
    }

    // MARK: 跟手

    private func allows(_ direction: PagerArbiter.Direction) -> Bool {
        let index = Dock.order(resting)
        return direction == .previous ? index > 0 : index < Self.last || motion.shot != nil
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

    /// 跟手；那一侧没有页时越拖越沉（同系统滚动到头的阻尼）。露出来的邻页现成就画上，还没建时当场建。
    private func follow(_ translation: CGFloat) {
        let direction: PagerArbiter.Direction = translation > 0 ? .previous : .next
        let index = Dock.order(resting) + (direction == .previous ? -1 : 1)
        if Dock.tabs.indices.contains(index), !moving.contains(Dock.tabs[index]) {
            build(Dock.tabs[index])
            show(moving: moving.union([resting, Dock.tabs[index]]))
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

    /// 松手：按甩出的方向估落点，过了半页就去那一页，否则回原处；弹簧接着手指的速度走（Core Animation 播），再请 root 跟上。
    private func settle(velocity: CGFloat, commits: Bool) {
        let index = Dock.order(resting), w = max(width, 1)
        let moved = offset + CGFloat(index) * w, projected = moved + velocity * 0.2
        var target = index
        if commits, projected > w / 2, velocity > -200, allows(.previous) { target = index - 1 }
        if commits, projected < -w / 2, velocity < 200, allows(.next) { target = index + 1 }
        let turned = target != index && target <= Self.last
        if turned { show(resting: Dock.tabs[target], moving: moving) }
        animate(to: -CGFloat(target) * w, velocity: velocity) { [weak self] in
            if target > Self.last { self?.commitForward() } else { self?.rest() }
        }
        if turned { workspace.tapSoon(resting) }
    }

    /// 切页只有这一条弹簧：松手、点按、深链都经它；条的图层与 SwiftUI 那一层（底部那一排、前进页）同一条（`Motion.nudge`）、同一个初速度。
    private func animate(to target: CGFloat, velocity: CGFloat = 0, done: @escaping () -> Void) {
        turn += 1
        let current = turn
        let distance = target - offset
        let initial = abs(distance) > 1 ? min(max(velocity / distance, -20), 20) : 0
        let spring = Motion.Spring.nudge
        offset = target
        withAnimation(Motion.nudge(velocity: initial)) {
            UIView.animate(
                springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: initial,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self.apply(target)
            } completion: { [weak self] _ in
                guard let self, current == self.turn else { return }
                done()
            }
        }
    }

    /// 停稳：滑过的页藏起来、不订阅；还有没建的页接着等空闲再建。
    private func rest() {
        show(moving: [])
        buildLater()
    }

    /// 拉到前进页松手：快照停在原处，下一轮不带动画地推入真的页（同 `Workspace.tapSoon` 的理由），它画上屏后收起快照、这一条回到 Cue 页（推入的页盖着）。
    private func commitForward() {
        handing = true
        Task { [weak self] in
            guard let self, let route = self.shot.route else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { self.workspace.goForward(to: route) }
            self.shot.forget()
            await NextFrame.drawn()
            self.handing = false
            self.offset = -CGFloat(Self.last) * max(self.width, 1)
            withTransaction(still) {
                self.motion.shot = nil
                self.apply(self.offset)
            }
            self.motion.busy = false
        }
    }

    // MARK: 换 tab

    /// root 换了（点底部那一排、深链、提示）而条还没挪过去：整条从此刻的位置滑过去（弹簧半路再点也是接着走），一路要露出来的页还没建的先建、等一帧排好再滑；
    /// 减弱动态效果时直接换。
    private func slide(to root: Route) {
        guard root != resting else { return }
        let from = Dock.order(resting), to = Dock.order(root)
        let span = Set(Dock.tabs[min(from, to)...max(from, to)])
        let missing = span.contains { pages[$0] == nil }
        for route in span { build(route) }
        idle?.cancel()
        guard !(environment?.accessibilityReduceMotion ?? false), view.window != nil else {
            stopAnimations()
            show(resting: root, moving: [])
            offset = -CGFloat(to) * width
            apply(offset)
            return rest()
        }
        show(resting: root, moving: moving.union(span))
        guard missing else { return animate(to: -CGFloat(to) * width) { [weak self] in self?.rest() } }
        Task { [weak self] in
            await NextFrame.wait()
            guard let self, self.resting == root else { return }
            self.animate(to: -CGFloat(to) * self.width) { [weak self] in self?.rest() }
        }
    }

    /// 读屏的三指左右滑：换到那一边的 tab。
    private func scroll(toward edge: UIAccessibilityScrollDirection) -> Bool {
        let index = Dock.order(resting) + (edge == .right ? -1 : edge == .left ? 1 : 0)
        guard index != Dock.order(resting), Dock.tabs.indices.contains(index) else { return false }
        workspace.tapSoon(Dock.tabs[index])
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
