import QuartzCore
import SwiftUI

/// 对话内容在渲染端的平移（新到的一条把上面的对话撑上去，`ChatScroll.rise`）：给滚动区里装内容的那一层叠一段相对的竖直平移，
/// 从让出的高无回弹地回到 0（`Motion.move` 的曲线与时长），全在 Core Animation 的渲染端跑，动画里主线程不重排、不读几何。
/// 叠加（`additive`）、每次各用各的键：上一段没走完又来一条时两段相加，屏上从当前位置连续接上。
/// 否决的方案：SwiftUI 的偏移逐帧挪——每帧要主线程更新，Mac 上发出一句到回复与结果卡出来的那几秒主线程指令多近两成。
/// 挪哪一层由内容里一个不占地方的平台视图往上找（`Anchor`）；顺着它也找到平台的滚动视图，直接挪偏移（`scroll(by:)`）。
@MainActor final class ContentLift {
    weak var probe: PlatformView?
    private var slides = 0

    func slide(by height: CGFloat) {
        guard let layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = downIsPositive ? height : -height
        slide.toValue = 0
        slide.isAdditive = true
        slide.duration = Motion.moveDuration
        slide.timingFunction = CAMediaTimingFunction(controlPoints: Float(Motion.moveCurve.0), Float(Motion.moveCurve.1), Float(Motion.moveCurve.2), Float(Motion.moveCurve.3))
        slides += 1
        layer.add(slide, forKey: "lift.\(slides)")
    }

    /// 可见区沿内容往下挪 `height`：正在读的那一条在内容里挪了这么多时（`ChatAnchor`），它留在原处。直接改平台滚动视图的偏移，
    /// 在内容变高的这次更新里生效、这一帧就画在原处，正滚着（触控板的惯性、滚轮、手指拖着）也接着从新的位置滚。
    /// 否决的方案：SwiftUI 的滚动位置（`ScrollPosition.scrollTo(y:)`）晚一次更新才用上，Mac 上正滚着时常被滚动盖掉：正在读的被推下去一整段，
    /// 离最早那头仍不到一屏、不再排开更早的，停在"更早的 N 条"上；按底边锚定（`defaultScrollAnchor(_:for: .sizeChanges)`）正滚着时系统不管。
    func scroll(by height: CGFloat) {
        #if os(iOS)
        var view = probe?.superview
        while let current = view, !(current is UIScrollView) { view = current.superview }
        guard let scroll = view as? UIScrollView else { return }
        scroll.contentOffset.y += height
        #else
        guard let scroll = probe?.enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + height))
        scroll.reflectScrolledClipView(clip)
        #endif
    }

    /// 挪的是滚动区里装内容的那一层，滚动区自己的裁剪与滚动条不动；挂到窗口上时层还没建，到挪的时候再找。
    #if os(iOS)
    private var downIsPositive: Bool { true }
    private var layer: CALayer? {
        sequence(first: probe, next: \.?.superview).first { $0?.superview is UIScrollView }??.layer
    }
    #else
    /// 平移在内容那一层的上一层（滚动区的裁剪视图）里算：它跟着内容翻转（SwiftUI 的滚动区是），y 就朝下。
    /// 当成 Mac 的层一律 y 朝上的话方向反了：新到的一条插进来时整段先多窜上去一截、再往下落回终位。
    private var downIsPositive: Bool { probe?.enclosingScrollView?.contentView.isFlipped ?? true }
    private var layer: CALayer? { probe?.enclosingScrollView?.documentView?.layer }
    #endif

    /// 放在内容里（`background`）认出装内容那一层的平台视图。
    struct Anchor {
        let lift: ContentLift
    }

    final class Probe: PlatformView {
        #if os(macOS)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        #endif
    }
}

#if os(iOS)
typealias PlatformView = UIView
extension ContentLift.Anchor: UIViewRepresentable {
    func makeUIView(context: Context) -> ContentLift.Probe {
        let probe = ContentLift.Probe()
        probe.isUserInteractionEnabled = false
        lift.probe = probe
        return probe
    }

    func updateUIView(_ probe: ContentLift.Probe, context: Context) {}
}
#else
typealias PlatformView = NSView
extension ContentLift.Anchor: NSViewRepresentable {
    func makeNSView(context: Context) -> ContentLift.Probe {
        let probe = ContentLift.Probe()
        lift.probe = probe
        return probe
    }

    func updateNSView(_ probe: ContentLift.Probe, context: Context) {}
}
#endif
