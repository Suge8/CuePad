#if os(macOS)
import AppKit

/// 开合侧栏的滑动（`MacPages.toggleSidebar`）：分栏与工具栏在按下的这一圈就不带动画地换到终点（页按新的宽排一次），
/// 看得见的滑动全是 Core Animation 的叠加动画，在渲染端跑，动画里主线程没有活。
/// 每次开合，侧栏的边的终点换了一次（展开是侧栏的宽，收起是 0）；每层都给一段"相对模型值的偏移"，从新旧位置之差按同一条弹簧曲线（`SlideCurve`）回到 0，
/// 叠加在模型值上（`additive`），旧的那段不移除、照常跑完。途中反向时屏上的位置因此是渲染端逐帧把几段相加出来的，从提交落地那一刻的真实位置连续接上，
/// 不管这一圈主线程晚多久提交（按下时算好绝对位置再起新动画的话，主线程忙的那几十毫秒里旧动画照样往前走，接上时要往回退一截）。
/// 随侧栏滑的图层是一个集合：
/// - 整个分栏（侧栏连同它的阴影）：偏移就是边的偏移；收起后侧栏的模型位置还在原处（只是藏起），另叠一段停在负的侧栏宽上，与偏移同时结束；
/// - 详情区这一栏（在分栏里）：页的模型左缘跟着分栏换了（展开是侧栏的宽，收起是 0），新旧之差已在边的偏移里；收起时补回分栏那段停留，页的左缘一直贴着侧栏的边；
/// - 工具栏里随侧栏摆的项：随侧栏的边在收起与展开两个位置之间线性地滑（`riderMoved`）；
/// - 侧栏那一格：收起后分栏已经把它藏起，滑出去的这段时间照样画出来（对 `hidden` 的动画）。
/// 收起时叠的两段停留与 `hidden` 在展开时撤下：撤下的一截与新偏移的起点正好抵消。减弱动态效果时不滑，直接到终点。
/// 动画在分栏真换过去的那次布局里才加（`splitResized`；工具栏项在随后同一次布局里摆到终点时补上，`riderMoved`），与分栏、页、工具栏的变化同一次提交。
/// 否决的方案：让分栏自己动画——AppKit 每帧在主线程摆一遍分栏、重排工具栏、重算窗口拖动区域、通知 SwiftUI 安全区变了，前台每帧 5～7ms（144Hz 一帧只有 6.9ms），
/// 开头还有几圈 11～25ms；收起先滑完再交给分栏——滑完的那一圈收分栏、重排工具栏与详情区要 30ms 上下；用 SwiftUI 的偏移逐帧挪——每帧重新摆整页。
final class SidebarSlide {
    /// 详情区这一栏（`ColumnFinder`）：父视图是它在分栏里的那一格，再往上是分栏。
    weak var column: NSView?
    /// 刚按下开合、等分栏换过去：要展开为 true。
    private var expecting: Bool?
    private var motion: SlideCurve?
    private var motions = 0
    /// 这次开合在工具栏项上用的键（`riderMoved`）。
    private var riderKey = ""
    /// 工具栏里随侧栏摆的项：这次开合之前在哪（窗口坐标的框），按项。
    private var riders: [ObjectIdentifier: CGRect] = [:]
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func expect(opening: Bool) { expecting = opening }

    /// 详情区离开了窗口（`ColumnFinder`）：注销对工具栏各项的观察，回到窗口时下次开合再按那时的工具栏挂上。
    func leaveWindow() {
        observers.values.forEach(NotificationCenter.default.removeObserver)
        observers = [:]
        riders = [:]
        motion = nil
    }

    /// 分栏摆过一遍（`ColumnFinder` 听分栏的通知，同一次布局里同步投递）。
    func splitResized(_ split: NSSplitView) {
        guard let opening = expecting, let column, let cell = column.superview,
              let bar = split.arrangedSubviews.first(where: { $0 !== cell }), split.isSubviewCollapsed(bar) != opening,
              let splitLayer = split.layer, let columnLayer = column.layer, let barLayer = bar.layer
        else { return }
        expecting = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // 分栏与详情区那一格按自己的框裁剪，裁剪框随平移一起走：收起时页右边一截（已按终点的宽排好）、展开时页右边多铺的底色被裁掉，
        // 滑动途中窗口右缘露出窗口的白底。停下时它们与窗口一样大，不裁也不多画什么
        [split, cell].forEach { $0.clipsToBounds = false }
        // 侧栏收起后它那一格的宽照旧：就是展开时侧栏的边
        let width = bar.frame.width
        let next = SlideCurve(from: opening ? 0 : width, to: opening ? width : 0, width: width)
        motions += 1
        motion = next
        // 每次开合一段，各用各的键：后加的不替下还在跑的
        let key = "\(Self.slideKey).\(motions)"
        splitLayer.add(next.offset { $0 }, forKey: key)
        if opening {
            [splitLayer, columnLayer].forEach { $0.removeAnimation(forKey: Self.holdKey) }
            barLayer.removeAnimation(forKey: Self.hiddenKey)
        } else {
            splitLayer.add(next.hold(Self.slideKey, at: -width), forKey: Self.holdKey)
            columnLayer.add(next.hold(Self.slideKey, at: width), forKey: Self.holdKey)
            barLayer.add(next.hold(Self.hiddenKey, at: false), forKey: Self.hiddenKey)
        }
        watchRiders(in: split.window, key: key)
    }

    /// 工具栏这时还没重排：记下各项此刻（开合之前）的左缘，它们摆到终点时（`riderMoved`）按两头补上动画。
    /// 随侧栏摆的项是工具栏各项最近的共同容器里的那几格（玻璃底的项外面还包着一层底板，平移的是那一格）。
    private func watchRiders(in window: NSWindow?, key: String) {
        let views = window?.toolbar?.items.compactMap(\.view) ?? []
        guard let first = views.first,
              let container = sequence(first: first, next: \.superview).first(where: { box in views.allSatisfy { $0.isDescendant(of: box) && $0 !== box } })
        else { return }
        riders = [:]
        riderKey = key
        for rider in container.subviews {
            let id = ObjectIdentifier(rider)
            riders[id] = Self.frame(of: rider)
            guard observers[id] == nil else { continue }
            observers[id] = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: rider, queue: nil) { [weak self, weak rider] _ in
                MainActor.assumeIsolated { rider.map { self?.riderMoved($0) } }
            }
        }
    }

    /// 工具栏的一项摆了位置（同步投递；同一次重排里可能摆好几回，以最后一回为准，同一个键替下）：在滑的时候叠一段偏移，
    /// 从开合之前的位置随侧栏的边滑到这里。变了宽的是这次出现或消失的项（侧栏收起时才有的项目切换），没有开合之前的位置可滑，原地出没。
    private func riderMoved(_ rider: NSView) {
        let now = CACurrentMediaTime()
        guard let motion, now < motion.begin + motion.duration, let frame = riders[ObjectIdentifier(rider)], let layer = rider.layer else { return }
        let before = frame.minX, moved = Self.frame(of: rider), after = moved.minX
        guard before != after, frame.width == moved.width else {
            layer.removeAnimation(forKey: riderKey)
            return
        }
        // 按侧栏的边在收起与展开两个位置之间线性取值：几段偏移叠加后仍是"边在哪、它就在哪"，途中反向也不会越过终点再退回来。
        // 不让它紧贴着侧栏的边、到收起位置停住（那是边的非线性函数，叠加的几段各自停住的时刻不同，反向后会越过收起的位置再退回来）；
        // 线性取值时它总在紧贴的位置右边，不会盖到还没滑走的侧栏上。
        let opening = motion.to > motion.from
        let (closed, open) = opening ? (before, after) : (after, before)
        layer.add(motion.offset { edge in closed + (open - closed) * (motion.to + edge) / motion.width - after }, forKey: riderKey)
    }

    private static func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    private static let slideKey = "transform.translation.x"
    private static let hiddenKey = "hidden"
    private static let holdKey = "sidebar.hold"
}

/// 一次开合里侧栏的边怎么走：从 `from` 到 `to`（总是隔着侧栏的宽），曲线同 `Motion.snappy`（不回弹的弹簧，0.25 秒）。
private struct SlideCurve {
    /// 按加动画的这一刻估的起点（真正的起点是这次提交送到渲染端的时刻）：只用来判断工具栏重排时还在不在滑。
    let begin = CACurrentMediaTime()
    let from: CGFloat
    let to: CGFloat
    let width: CGFloat
    let duration: TimeInterval

    init(from: CGFloat, to: CGFloat, width: CGFloat) {
        self.from = from
        self.to = to
        self.width = width
        duration = Self.settles(over: abs(to - from))
    }

    private static let omega = 2 * Double.pi / 0.25
    /// 关键帧每秒取样多少次：比 144Hz 密，帧之间按直线插值看不出折线。
    private static let samplesPerSecond = 240.0

    /// 临界阻尼弹簧离终点的比例是 (1 + ωt)·e^(−ωt)。
    private static func remaining(_ time: Double) -> Double { (1 + omega * time) * exp(-omega * time) }

    /// 滑这么远时离终点不到半点要多久：到这时就算滑完。弹簧按比例收敛到 `settlingDuration` 要多等 0.1 秒左右，那时早已看不出在动。
    private static func settles(over distance: CGFloat) -> TimeInterval {
        var time = 0.0
        while Double(distance) * remaining(time) > 0.5 { time += 0.005 }
        return time
    }

    /// 叠加在模型值上的一段平移偏移：边相对终点的偏移从 `from - to` 按曲线回到 0，`translation` 把它换算成这一层的偏移（到 0 时也得是 0）。
    func offset(_ translation: (CGFloat) -> CGFloat) -> CAKeyframeAnimation {
        let steps = max(1, Int((duration * Self.samplesPerSecond).rounded(.up)))
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = (0...steps).map { step in
            translation(step == steps ? 0 : (from - to) * CGFloat(Self.remaining(duration * Double(step) / Double(steps))))
        }
        animation.isAdditive = true
        return timed(animation)
    }

    /// 在 `keyPath` 上停在 `value` 直到滑完：平移是叠加在模型值上的一截，`hidden` 是换掉模型值。
    func hold(_ keyPath: String, at value: Any) -> CABasicAnimation {
        let hold = CABasicAnimation(keyPath: keyPath)
        hold.fromValue = value
        hold.toValue = value
        hold.isAdditive = value is CGFloat
        return timed(hold)
    }

    /// 不写起点：同一次提交里加的动画都从那次提交起，几段一起开始、一起结束。没开始前停在第一帧的值（叠加的偏移这时正好抵消模型值的跳变）。
    private func timed<A: CAAnimation>(_ animation: A) -> A {
        animation.duration = duration
        animation.fillMode = .backwards
        return animation
    }
}
#endif
