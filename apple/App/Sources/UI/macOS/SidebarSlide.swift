#if os(macOS)
import AppKit

/// 会话条换宽时两栏的滑动（`WideColumnView.move`）：两栏在按下的这一圈就不带动画地换到终点的位置与宽（页按新的宽排一次），
/// 看得见的滑动全是 Core Animation 的叠加动画，在渲染端跑，动画里主线程没有活。
/// 每次换宽给一段"相对模型值的偏移"，从新旧之差按同一条弹簧曲线（`SlideCurve`）回到 0，叠加在模型值上（`additive`），旧的那段不移除、照常跑完。
/// 途中反向时屏上的位置因此是渲染端逐帧把几段相加出来的，从提交落地那一刻的真实位置连续接上，不管这一圈主线程晚多久提交
/// （按下时算好绝对位置再起新动画的话，主线程忙的那几十毫秒里旧动画照样往前走，接上时要往回退一截）。减弱动态效果时不滑，直接到终点。
/// 否决的方案：让栏宽逐帧动画——AppKit 每帧在主线程重排整窗、重算鼠标跟踪区并重设光标；用 SwiftUI 的偏移逐帧挪——每帧重新摆整页。
enum SidebarSlide {
    static func translate(_ layer: CALayer, by distance: CGFloat, key: String) {
        slide(layer, "transform.translation.x", by: distance, key: key)
    }

    /// 在 `keyPath` 上叠一段从 `distance` 回到 0 的偏移（同 `translate` 的曲线；栏的右缘用 `bounds.size.width`）。
    static func slide(_ layer: CALayer, _ keyPath: String, by distance: CGFloat, key: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, distance != 0 else { return }
        layer.add(SlideCurve(distance: distance).offset(keyPath), forKey: key)
    }
}

/// 一段偏移怎么回到 0：曲线是 `Motion.nudge` 那条弹簧（`Motion.Spring.nudge`），离终点不到半点时收住。
/// 离终点的比例只随时间走、与距离无关：同一次换宽里的几段（两栏的平移、右缘的宽）每一帧按同样的比例收敛，彼此对得上。
private struct SlideCurve {
    let distance: CGFloat
    let duration: TimeInterval

    init(distance: CGFloat) {
        self.distance = distance
        duration = Self.settles(over: abs(distance))
    }

    private static let omega = 2 * Double.pi / Motion.Spring.nudge.duration
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

    /// 叠加在模型值上的一段偏移：从 `distance` 按曲线回到 0。不写起点：同一次提交里加的动画都从那次提交起，几段一起开始、一起结束；
    /// 没开始前停在第一帧的值（叠加的偏移这时正好抵消模型值的跳变）。
    func offset(_ keyPath: String) -> CAKeyframeAnimation {
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
#endif
