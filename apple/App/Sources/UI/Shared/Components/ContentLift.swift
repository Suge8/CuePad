import QuartzCore
import SwiftUI

/// 贴着最新、内容在末尾长出来时整段从原处滑上去。叠加（`additive`）、每次各用各的键：上一段没走完又来一条时两段相加，屏上从当前位置连续接上。
/// 否决的方案：SwiftUI 的偏移逐帧挪——每帧要主线程更新，Mac 上发出一句到回复与结果卡出来的那几秒主线程指令多近两成。
/// 留在原处的那几块（`Unlifted`：在跑时的角色）在同一次提交里加一段反着的：两段都由渲染端按同一个时钟走，每一帧正好抵掉。
/// 否决的方案：那一块用 SwiftUI 的动画反着挪——它按主线程这次更新开始的时刻起算，整段上滑按提交的时刻起算，新的一条到的那一拍主线程正忙，
/// 两条曲线错开几十毫秒，那一块先被带下去一截再回来。
@MainActor final class ContentLift {
    weak var probe: PlatformView?
    private let still = NSHashTable<PlatformView>.weakObjects()
    private var slides = 0

    func slide(by height: CGFloat) {
        guard let content else { return }
        slides += 1
        glide(content, from: height)
        for view in still.allObjects { glide(view, from: -height) }
    }

    func hold(_ view: PlatformView, still holds: Bool) {
        if holds { still.add(view) } else { still.remove(view) }
    }

    private func glide(_ view: PlatformView, from height: CGFloat) {
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = height
        #if os(macOS)
        // 平移在这一层的上一层里算（内容的上一层是滚动区的裁剪视图）：它跟着内容翻转（SwiftUI 的滚动区是），y 就朝下。
        // 当成 Mac 的层一律 y 朝上的话方向反了：新到的一条插进来时整段先多窜上去一截、再往下落回终位。
        if view.superview?.isFlipped == false { slide.fromValue = -height }
        #endif
        slide.toValue = 0
        slide.isAdditive = true
        slide.duration = Motion.Glide.duration
        slide.timingFunction = Motion.Glide.timing
        let layer: CALayer? = view.layer
        layer?.add(slide, forKey: "lift.\(slides)")
    }

    /// 直接改平台滚动视图的偏移，在内容变高的这次更新里生效、这一帧就画在原处，正滚着（触控板的惯性、滚轮、手指拖着）也接着从新的位置滚。
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

    #if os(iOS)
    private var content: UIView? { sequence(first: probe, next: \.?.superview).first { $0?.superview is UIScrollView } ?? nil }
    #else
    private var content: NSView? { probe?.enclosingScrollView?.documentView }
    #endif

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

/// 整段上滑时留在原处的一块（`holds`：它排在末尾、屏上的位置不随这次长高变）。要自己的一层才能单独加动画，SwiftUI 的视图没有，
/// 所以里面另起一棵树（宿主视图），外面的环境原样带进去。里面认不到外面的滚动区与命名坐标空间：按它们量的（在不在可见区、在内容里的位置）挂在这一块外面；
/// 外面的动画事务也带不进去，里面要动的按值挂动画。不接点按、高由外面定。
/// 只给不被新内容穿过的那一块用：新的一条是从终位下方滑上来的，途中经过的地方有留在原处的东西就叠在一起（末尾的子代理那一行就不能留：回答逐行显出来时一直在滑）。
struct Unlifted<Content: View>: View {
    let holds: Bool
    @ViewBuilder let content: Content
    @Environment(\.chatLift) private var lift

    var body: some View { Host(lift: lift, holds: holds, content: content) }

    fileprivate struct Host {
        let lift: ContentLift?
        let holds: Bool
        let content: Content
    }

    fileprivate struct Rooted: View {
        let content: Content
        let environment: EnvironmentValues

        var body: some View {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).environment(\.self, environment)
        }
    }
}

#if os(iOS)
extension Unlifted.Host: UIViewRepresentable {
    func makeCoordinator() -> UIHostingController<Unlifted.Rooted?> { UIHostingController(rootView: nil) }

    func makeUIView(context: Context) -> UIView {
        let host = context.coordinator
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host.view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.rootView = Unlifted.Rooted(content: content, environment: context.environment)
        lift?.hold(view, still: holds)
    }
}
#else
extension Unlifted.Host: NSViewRepresentable {
    final class Surface: NSHostingView<Unlifted.Rooted?> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Surface {
        let host = Surface(rootView: nil)
        host.safeAreaRegions = []
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: Surface, context: Context) {
        host.rootView = Unlifted.Rooted(content: content, environment: context.environment)
        lift?.hold(host, still: holds)
    }
}
#endif
