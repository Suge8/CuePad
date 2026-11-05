#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 宽屏会话条换宽、Cue 收起与放回时几块的滑动（`WideColumnSlide`）：各块在按下的这一圈就不带动画地换到终点的位置与宽（页按新的宽排一次），
/// 看得见的滑动全是 Core Animation 的叠加动画，在渲染端跑，动画里主线程没有活。
/// 每次换宽给一段"相对模型值的偏移"，从新旧之差按同一条弹簧曲线（`SlideCurve`）回到 0，叠加在模型值上（`additive`），旧的那段不移除、照常跑完。
/// 途中反向时屏上的位置因此是渲染端逐帧把几段相加出来的，从提交落地那一刻的真实位置连续接上，不管这一圈主线程晚多久提交
/// （按下时算好绝对位置再起新动画的话，主线程忙的那几十毫秒里旧动画照样往前走，接上时要往回退一截）。减弱动态效果时不滑，直接到终点。
///
/// 块整个平移只对得上一种对齐：页按终点的宽排过，居中的阅读栏、靠右的钮、随会话条让出的栏头字，各自离块左缘的距离都变了。
/// 所以块里每一层另按自己补（`Positions`）：排之前记下各层离块左缘多远，排完再量一次，差多少就叠一段同曲线的偏移从旧处回到新处，
/// 页里的东西不论怎么对齐都从自己的旧位置连续走到新位置，不用页声明谁按什么对齐。层按对象认（SwiftUI 排版前后沿用同一个层）；
/// 排完才有的层（宽了才放得下的计时、横滑区里新露出的卡）没有旧位置可滑，随它的上一层走、等别的快落定才淡入（`SlideCurve.appear`）：
/// 不然它这一下就在终点，挡在还在滑过来的字前面。
/// 没画内容的层（容器、裁剪区、纯色与圆角的底）宽也从旧宽走到新宽：卡片的底跟着它里面的字一起收放，横滑区不把从旧处滑来的列裁掉。
/// 画了内容的层（文字、图）宽直接到位——拉伸位图会把字压扁；文字的断行这一下就换成终点的。变宽的那些滑动期间另挂一层遮罩，露出的宽同曲线从旧宽走到新宽
/// （`reveals`）：按终点排宽的一行字不越出还在长的卡片、伸进旁边那一列，滑完撤掉。只补横向：竖向因换行而变的直接到位。
/// 否决的方案（数据见 docs/layout.md「宽屏开合」）：逐帧排版（栏宽逐帧动画，或逐帧把栏宽交给页）——主线程每帧按当时的宽重排整页，掉帧、长圈；
/// 页内一个 SwiftUI 布局动画——每帧照样重摆懒加载列表、按插值的尺寸重画文字，开头几帧被终点那一次排版堵住，SwiftUI 画的部分一帧跳完。
enum WideSlide {
    /// 叠一段从 `distance` 回到 0 的平移。
    static func translate(_ layer: CALayer, by distance: CGFloat, key: String) {
        slide(layer, "transform.translation.x", by: distance, key: key)
    }

    /// 在 `keyPath` 上叠一段从 `distance` 回到 0 的偏移（同 `translate` 的曲线；栏的右缘用 `bounds.size.width`）。
    static func slide(_ layer: CALayer, _ keyPath: String, by distance: CGFloat, key: String) {
        guard !reduceMotion, abs(distance) >= SlideCurve.rest else { return }
        layer.add(SlideCurve(distance: distance).offset(keyPath), forKey: key)
    }

    /// 排完才有的层：先不显，同一次滑动快落定时淡入。
    static func appear(_ layer: CALayer, key: String) {
        guard !reduceMotion, layer.opacity > 0 else { return }
        layer.add(SlideCurve(distance: -CGFloat(layer.opacity)).appear("opacity"), forKey: key)
    }

    private static var reduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// 块里各层离块左缘多远（模型值，排版前记、排完比，`follow`）。藏起与全透明的不记：看不见，排不排都一样。
    /// 握着层本身：这一圈里它们不会被释放、地址不会给了新层而认错。
    /// 页不一定一次排齐（`WideColumnSlide.layoutPasses`）：补第二遍时只补这一遍新挪的那一截，每层自己已叠上多少记在 `own`，收放宽度、遮罩与淡入每层只做一次。
    struct Positions {
        private var lefts: [ObjectIdentifier: (layer: CALayer, x: CGFloat, width: CGFloat)] = [:]
        /// 各层自己已叠上的平移（不含上一层的）。
        private var own: [ObjectIdentifier: CGFloat] = [:]
        private var resized: Set<ObjectIdentifier> = []
        private var appeared: Set<ObjectIdentifier> = []
        /// 第几遍：每遍的动画用自己的键，不顶掉前几遍叠上的。
        private var pass = 0

        init(_ root: CALayer) { visit(root, at: 0) }

        private mutating func visit(_ layer: CALayer, at x: CGFloat) {
            for sublayer in layer.sublayers ?? [] where Self.shown(sublayer) {
                let left = x + sublayer.frame.minX - layer.bounds.minX
                lefts[ObjectIdentifier(sublayer)] = (sublayer, left, sublayer.bounds.width)
                visit(sublayer, at: left)
            }
        }

        static func shown(_ layer: CALayer) -> Bool { !layer.isHidden && layer.opacity > 0 }

        /// 收放宽度看起来不变形：没有位图内容、不是按固定路径画的。
        private static func stretches(_ layer: CALayer) -> Bool {
            layer.contents == nil && !(layer is CAShapeLayer) && !(layer is CATextLayer)
        }

        /// 排完之后：每一层从记下的旧处滑到此刻的新处，扣掉上一层已经叠上的那段（偏移随层树相加）与自己前几遍叠上的；没记过的层随上一层走。
        mutating func follow(in root: CALayer, key: String) {
            guard !WideSlide.reduceMotion else { return }
            pass += 1
            var masked: [(layer: CALayer, mask: CALayer)] = []
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                for (layer, mask) in masked where layer.mask === mask { layer.mask = nil }
            }
            follow(root, at: 0, carried: 0, fading: false, key: "\(key).\(pass)", masked: &masked)
            CATransaction.commit()
        }

        /// 画了内容、变宽了的层：挂一层从旧宽长到新宽的遮罩（左缘对齐，同一条曲线）。已经有遮罩的不动（那是页自己的）。
        private static func reveal(_ layer: CALayer, from width: CGFloat, key: String) -> CALayer? {
            let growth = layer.bounds.width - width
            guard growth >= SlideCurve.rest, layer.mask == nil else { return nil }
            let mask = CALayer()
            mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            mask.anchorPoint = .zero
            mask.frame = CGRect(origin: layer.bounds.origin, size: layer.bounds.size)
            WideSlide.slide(mask, "bounds.size.width", by: -growth, key: key)
            layer.mask = mask
            return mask
        }

        private mutating func follow(_ layer: CALayer, at x: CGFloat, carried: CGFloat, fading: Bool, key: String, masked: inout [(layer: CALayer, mask: CALayer)]) {
            for sublayer in layer.sublayers ?? [] where Self.shown(sublayer) {
                let id = ObjectIdentifier(sublayer)
                let left = x + sublayer.frame.minX - layer.bounds.minX
                let before = lefts[id]
                let wanted = before.map { $0.x - left } ?? carried
                let change = before.map { $0.width - sublayer.bounds.width } ?? 0
                let resizes = abs(change) >= SlideCurve.rest && resized.insert(id).inserted
                // 宽从旧宽走到新宽时，图层按锚点收放：位置另补锚点那一份，左缘仍照 `wanted` 走
                let grows = resizes && Self.stretches(sublayer) ? change : 0
                WideSlide.slide(sublayer, "bounds.size.width", by: grows, key: key + ".w")
                WideSlide.slide(sublayer, "position.x", by: wanted - carried - (own[id] ?? 0) + sublayer.anchorPoint.x * grows, key: key)
                own[id] = wanted - carried
                if resizes, let before, !Self.stretches(sublayer), let mask = Self.reveal(sublayer, from: before.width, key: key + ".reveal") { masked.append((sublayer, mask)) }
                // 新层只在最外那一层淡入，里面的随它
                if before == nil, !fading, appeared.insert(id).inserted { WideSlide.appear(sublayer, key: key + ".fade") }
                follow(sublayer, at: left, carried: wanted, fading: fading || before == nil, key: key, masked: &masked)
            }
        }
    }
}

/// 宽屏的一块（主区、并排的右半、Cue 栏）怎么滑：Mac 的 `WideColumnView`、iPad 的 `WideColumnController` 各持一份，交给它块的图层与托管的页的根图层。
/// 会话条开合、Cue 收起或放回时，块这一下就到了终点的位置与宽（页按新的宽排一次），看得见的滑动是渲染端的叠加动画（`WideSlide`，主线程不逐帧挪）：
/// 整块从旧位置平移回来，右缘从旧宽收放到新宽；块里各层再按自己在页里挪了多少补齐（`WideSlide.Positions`：居中的、靠右的、让出开合钮的栏头字），
/// 页里每样东西都从自己的旧位置连续走到新位置。几块平移的距离不同（主区随会话条的边，并排的右半随两半的分界），只平移的话主区已按终点排宽、
/// 又多平移了一截，滑动途中右缘压进右边那一块；按终点的框裁又在两块之间露出一道缝。
/// 图层的宽按同一条曲线从旧宽走到新宽（只动右缘：按图层的锚点补上位置；页的排版不跟着变）：相邻两块的边每一帧都对齐。
/// 会话条自己一直不动（藏起时也照原宽画在主区下面，`WideRail`），看得见的只有主区像一张纸从它上面滑过：
/// 放回时主区从旧边起往右滑开、露出它；藏起时主区的左边往左滑回来盖住它——图层的左缘就停在终点、只把里面的页（铺满桌面色）按同一条曲线从旧处挪回来
/// （`bounds.origin.x`），左边还没盖到的那截透出的就是下面的会话条本身，行、字、选中的底都在，不是一块空的底色。
/// 收起的 Cue 栏排在窗口右缘外（`CueDock`）：收起、放回、跨过临界宽、抽屉开合同是一段平移，左缘每一帧贴着主区的右缘，滑出去落定才藏起（`park`）。
final class WideColumnSlide {
    private let slot: WideSlot
    private let apply: (_ hidden: Bool) -> Void
    private var previous: (origin: CGFloat, width: CGFloat, shape: WideMetrics.Shape)?
    private var sequence = 0
    /// 正在滑的那一次（`sequence`）；滑完是 nil。
    private var sliding: Int?
    private var hidden = false
    /// 滑完再藏起。
    private var hidesWhenLanded = false
    /// 页里各层排版前的位置与还要补几遍（`laidOut`）。
    private var pending: (positions: WideSlide.Positions, key: String, passes: Int)?
    /// 页里各层还等着页排完来补：页排完要报（`laidOut`）。
    var awaitsLayout: Bool { pending != nil }
    /// 页排几次才齐：Mac 的页在一个托管视图里，排一次就齐；iPad 的会话页在导航栈里另有一个托管视图，下一次提交才摆到层上（`WideColumnController.lastLayout`）。
    /// 不一直补到滑完：有的页滑动期间每帧排两次，每次都走一遍整页的层，主线程在动画里有了活（实测 Mac 大库上宽屏阈值测量随之读不出 Cue 栏的中段）。
    #if os(macOS)
    private static let layoutPasses = 1
    #else
    private static let layoutPasses = 2
    #endif

    /// `apply`：真的藏起或露出这一块（看不见、点不到、⌃Tab 跳过）。
    init(slot: WideSlot, apply: @escaping (_ hidden: Bool) -> Void) {
        self.slot = slot
        self.apply = apply
    }

    /// 在页按新宽排之前调（换根视图之前）：块里各层的旧位置这时记下。
    func move(_ layer: CALayer, page: CALayer, origin: CGFloat, width: CGFloat, shape: WideMetrics.Shape) {
        defer { previous = (origin, width, shape) }
        guard let previous, previous.shape != shape else { return }
        sequence += 1
        let turn = sequence
        sliding = turn
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.landed(turn) }
        defer { CATransaction.commit() }
        let distance = previous.origin - origin
        let edge: CGFloat
        if slot == .main, shape.rail < previous.shape.rail {
            WideSlide.slide(layer, "bounds.origin.x", by: -distance, key: "wide.\(turn)")
            edge = previous.width + distance - width
        } else {
            WideSlide.translate(layer, by: distance, key: "wide.\(turn)")
            edge = previous.width - width
        }
        WideSlide.slide(layer, "bounds.size.width", by: edge, key: "wide.edge.\(turn)")
        WideSlide.slide(layer, "position.x", by: layer.anchorPoint.x * edge, key: "wide.edge.anchor.\(turn)")
        if previous.width != width { pending = (WideSlide.Positions(page), "wide.page.\(turn)", Self.layoutPasses) }
    }

    /// 页按新宽排完（托管视图排版之后调）：各层从记下的旧处滑到此刻的新处，同一次提交里起步；第二遍只补新挪的（`Positions`）。没排齐就滑完了的作废（`landed`）。
    func laidOut(_ page: CALayer) {
        guard var pending else { return }
        pending.positions.follow(in: page, key: pending.key)
        pending.passes -= 1
        self.pending = pending.passes > 0 ? pending : nil
    }

    /// 藏起或露出（收起的 Cue 仍挂着，只是藏起）。正在滑走时等滑完再藏，露出当即露出。
    func park(_ hidden: Bool) {
        hidesWhenLanded = hidden && sliding != nil && !self.hidden
        guard !hidesWhenLanded, hidden != self.hidden else { return }
        self.hidden = hidden
        apply(hidden)
    }

    private func landed(_ turn: Int) {
        guard sliding == turn else { return }
        sliding = nil
        pending = nil
        guard hidesWhenLanded else { return }
        hidesWhenLanded = false
        hidden = true
        apply(true)
    }
}

/// 一段偏移怎么回到 0：曲线是 `Motion.nudge` 那条弹簧（`Motion.Spring.nudge`）。
/// 离终点的比例只随时间走、与距离无关，几段都一样长（`duration`）：同一次换宽里的几段（各块的平移、右缘的宽、块里各层的补位）每一帧按同样的比例收敛、
/// 同一刻收住，彼此对得上——按各自的距离定长短的话，各段在不同的时刻甩掉最后那不到半点，相加出来停下前会来回抖一点。
private struct SlideCurve {
    let distance: CGFloat

    /// 不到这么远的不滑：看不出来。
    static let rest: CGFloat = 0.5
    /// 一次换宽里最远的一段（会话条与 Cue 一起变）离终点不到半点要多久：到这时就算滑完。
    /// 弹簧按比例收敛到 `settlingDuration` 要多等 0.1 秒左右，那时早已看不出在动。
    private static let duration = settles(over: Chrome.rail + WideMetrics.cue)

    private static let omega = 2 * Double.pi / Motion.Spring.nudge.duration
    /// 关键帧每秒取样多少次：比 144Hz 密，帧之间按直线插值看不出折线。
    private static let samplesPerSecond = 240.0

    /// 临界阻尼弹簧离终点的比例是 (1 + ωt)·e^(−ωt)。
    private static func remaining(_ time: Double) -> Double { (1 + omega * time) * exp(-omega * time) }

    private static func settles(over distance: CGFloat) -> TimeInterval {
        var time = 0.0
        while Double(distance) * remaining(time) > Double(rest) { time += 0.005 }
        return time
    }

    /// 离终点还剩这么多时才开始淡入（`appear`）：前面那截别的东西还在大步挪。
    private static let appearsAt = 0.15

    /// 同 `offset`，但离终点剩 `appearsAt` 之前一直停在 `distance`（不透明度叠上 -1 就是不显），之后随曲线回到 0。
    func appear(_ keyPath: String) -> CAKeyframeAnimation {
        let animation = offset(keyPath)
        animation.values = animation.values?.map { value in
            let left = (value as? CGFloat ?? 0) / distance
            return distance * min(1, left / Self.appearsAt)
        }
        return animation
    }

    /// 叠加在模型值上的一段偏移：从 `distance` 按曲线回到 0。不写起点：同一次提交里加的动画都从那次提交起，几段一起开始、一起结束；
    /// 没开始前停在第一帧的值（叠加的偏移这时正好抵消模型值的跳变）。
    func offset(_ keyPath: String) -> CAKeyframeAnimation {
        let duration = Self.duration
        let steps = max(1, Int((duration * Self.samplesPerSecond).rounded(.up)))
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...steps).map { step in
            step == steps ? 0 : distance * CGFloat(Self.remaining(duration * Double(step) / Double(steps)))
        }
        animation.isAdditive = true
        animation.duration = duration
        animation.fillMode = .backwards
        return animation
    }
}

