import QuartzCore
import SwiftUI

/// 对话内容在渲染端的平移（新到的一条把上面的对话撑上去，`ChatScroll.rise`）：给滚动区里装内容的那一层叠一段相对的竖直平移，
/// 从让出的高无回弹地回到 0（`Motion.move` 的曲线与时长），全在 Core Animation 的渲染端跑，动画里主线程不重排、不读几何。
/// 叠加（`additive`）、每次各用各的键：上一段没走完又来一条时两段相加，屏上从当前位置连续接上。
/// 否决的方案：SwiftUI 的偏移逐帧挪——每帧要主线程更新，Mac 上发出一句到回复与结果卡出来的那几秒主线程指令多近两成。
/// 挪哪一层由内容里一个不占地方的平台视图往上找（`Anchor`）。
@MainActor final class ContentLift {
    weak var probe: PlatformView?
    private var slides = 0

    func slide(by height: CGFloat) {
        guard let layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = Self.downIsPositive ? height : -height
        slide.toValue = 0
        slide.isAdditive = true
        slide.duration = Motion.moveDuration
        slide.timingFunction = CAMediaTimingFunction(controlPoints: Float(Motion.moveCurve.0), Float(Motion.moveCurve.1), Float(Motion.moveCurve.2), Float(Motion.moveCurve.3))
        slides += 1
        layer.add(slide, forKey: "lift.\(slides)")
    }

    /// 挪的是滚动区里装内容的那一层，滚动区自己的裁剪与滚动条不动；挂到窗口上时层还没建，到挪的时候再找。
    #if os(iOS)
    private static let downIsPositive = true
    private var layer: CALayer? {
        sequence(first: probe, next: \.?.superview).first { $0?.superview is UIScrollView }??.layer
    }
    #else
    /// Mac 的层 y 朝上。
    private static let downIsPositive = false
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
