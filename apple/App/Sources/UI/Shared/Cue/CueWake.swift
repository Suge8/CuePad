import CueStore
import QuartzCore
import SwiftUI

/// Cue 被会话叫醒的那一下（"接力"）：一点晴蓝的光从叫醒它的会话的状态标起飞，沿一道弧飞到 Cue 的头像，落下时头像的环亮起、
/// 漾开一圈，接上它在想时的转环。晴蓝是在跑的颜色（`Palette.live`）：会话把"在跑"交棒给 Cue，用户一眼看出是谁叫醒了它。
/// iOS 与 Mac 同一套样子、同一份时长；只在真的叫醒的那一刻出现，几个会话一起叫醒就各飞一道、错开 90ms，最多三道（再多就成了一片光，看不出谁是谁）。
///
/// 时长：起飞处一圈细环外扩（0.45s，缓出）；光飞 0.42～0.72s（随距离：侧栏里一跳短，手机上从列表飞到底栏长），曲线先加速、
/// 后长长地减速，落进头像时已经很慢——"被接住"，不是"撞上"；还差最后一成路时头像的环亮起（带一圈同色光晕）、停一下再外扩到 1.6 倍淡去
/// （0.7s），晚 0.12s 一圈细涟漪扩到 2.1 倍（0.75s）；不盖住它的脸。光后面拖一截由亮到暗的尾巴（同一条弧上的描边，起点追着终点走、
/// 落下时被收进去），比单独一个点更看得出从哪来、到哪去。弧向窗口竖中线那边鼓（从侧栏、屏边起飞时弧在屏内）。整个过程约 1.3s：
/// 这是全 App 唯一超过 300ms 的动效（docs/ui.md），它讲的是一件低频的事从哪到哪，短了看不清起点。
///
/// 降级：
/// - 起点不在屏幕上（那个会话不在这一页、滚出去了）：只在头像上亮环、漾开。
/// - 终点不在屏幕上（Mac 侧栏收起且不在 Cue 页，手机在会话页、纸页这类收起了底栏的页）：起飞的环照样扩开，光从状态标升起一小段就淡去——
///   说"它把事交出去了"，不在别处凭空画一个假的落点，也不往屏外飞（Mac 会话页的状态在工具栏里，上面就是窗口的边）；
///   两头都不在就什么都不画：没有一个看得见的东西能把这件事讲清楚，Cue 的头像回到屏幕上时自己就在转环。
/// - 减弱动态效果：不飞、不扩，头像的环与起点的状态标同时淡入一层高亮再淡出（1s），同 `Motion` 的约定只留透明度。
///
/// 动画状态只来自唤醒事实（`CueState.woke`）：`woke.at` 变成新的非空值就播一次，不另存；窗口读到的第一份不播（App 刚打开、
/// 窗口刚开时已有的叫醒不是此刻发生的），之后页面换来换去也不播（挂在窗口根上，不随页面出现）。
///
/// 性能：飞行整个交给 Core Animation（渲染服务插值，App 进程不逐帧参与），只在播时把一层画布挂到窗口的根层最上面，播完拿掉。
/// 不在每一行挂几何读数：只有被叫醒的那几个会话的状态标此刻挂一个空的锚视图（`wakeSource`），Cue 的几处头像各挂一个（`wakeTarget`）；
/// 播的那一刻沿层树把锚换算到窗口根层的坐标，一并算进父层的裁切、隐藏与透明（滚出屏的、被盖住的页、开合到 0 的都算不在），
/// 工具栏、导航容器、分栏这些各自托管的视图都在同一棵层树里，不需要逐层换算。
/// 否决了 SwiftUI 的覆盖层加锚点偏好：偏好过不了 Mac 工具栏与 iOS 导航容器的托管边界，覆盖层也盖不住 Mac 的工具栏。
struct CueWakeStage: ViewModifier {
    let cue: CueWatch
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = Stage()

    func body(content: Content) -> some View {
        let digest = cue.digest
        content
            .environment(\.cueWokeSessions, digest.state?.woke?.sessions ?? [])
            .background(Probe(stage: stage, color: palette.live))
            .onChange(of: digest) { old, new in
                guard old != .empty, let woke = new.state?.woke, woke.at != old.state?.woke?.at else { return }
                stage.play(woke.sessions, reduceMotion: reduceMotion || DebugHooks.preset.reducesMotion)
            }
    }

    /// 本窗口的舞台：认得窗口（`Probe`），播时找锚、交给 `WakeFlight`。
    final class Stage {
        fileprivate weak var host: WakeAnchorView?
        fileprivate var color: CGColor?

        func play(_ sessions: [String], reduceMotion: Bool) {
            Task {
                // 被叫醒的那几行这一刻才挂上锚（`wakeSource`）：等这一次更新排好、提交了再量
                await NextFrame.wait()
                guard let window = host?.window, let root = WakeAnchorView.rootLayer(of: window), let color else { return }
                let anchors = WakeAnchorView.all(in: window)
                let target = anchors.compactMap { anchor -> (rank: WakeTarget, frame: CGRect)? in
                    guard case .target(let rank) = anchor.role, let frame = anchor.frame(in: root) else { return nil }
                    return (rank, frame)
                }.max { $0.rank.rawValue < $1.rank.rawValue }?.frame
                // 同一个会话在屏上出现几处时（侧栏的行与任务上的状态），从离落点最近的那处起飞
                let sources = sessions.compactMap { session in
                    anchors.filter { $0.role == .source(session) }.compactMap { $0.frame(in: root) }
                        .min { WakeFlight.distance($0.center, target?.center) < WakeFlight.distance($1.center, target?.center) }?.center
                }
                WakeFlight(color: color, reduceMotion: reduceMotion).play(from: Array(sources.prefix(WakeFlight.most)), to: target, in: root)
            }
        }
    }

    /// 窗口根上一个空视图：让舞台认得自己在哪个窗口，并取当下配色里的晴蓝。
    fileprivate struct Probe {
        let stage: Stage
        let color: Color

        func make() -> WakeAnchorView {
            let view = WakeAnchorView(role: .stage)
            stage.host = view
            return view
        }
    }
}

extension EnvironmentValues {
    /// 叫醒 Cue 这一轮的会话（`CueState.woke` 的 `sessions`；不在被叫醒的一轮里为空，由 `CueWakeStage` 给）：只有它们的状态标挂锚。
    @Entry var cueWokeSessions: [String] = []
}

/// Cue 的头像出现的几处，同时在屏上时光落在等级高的那处。
enum WakeTarget: Int {
    /// 入口：Mac 侧栏最上面 Cue 那一行（也是菜单栏面板、输入条的那一行）、手机底栏 Cue 那一格。
    case entry
    /// 页头：Mac 与手机 Cue 页的页头——正看着 Cue 时落在它脸上。
    case header
}

extension View {
    /// 会话的状态标：这个会话叫醒 Cue 时光从这里起飞。只有被叫醒的会话挂锚，平时什么都不加。
    func wakeSource(_ session: String?) -> some View { modifier(WakeSource(session: session)) }

    /// Cue 的头像（或底栏那一格的图标）：光落在这里，环在这里亮起。
    func wakeTarget(_ rank: WakeTarget?) -> some View {
        background { if let rank { WakeAnchor(role: .target(rank)) } }
    }
}

private struct WakeSource: ViewModifier {
    let session: String?
    @Environment(\.cueWokeSessions) private var woke

    func body(content: Content) -> some View {
        content.background {
            if let session, woke.contains(session) { WakeAnchor(role: .source(session)) }
        }
    }
}

private struct WakeAnchor {
    let role: WakeAnchorView.Role
}

/// 锚：一个不接事件、不画东西的空视图，只为播的那一刻能沿层树量出它在窗口里的位置。
final class WakeAnchorView: WakeAnchorBase {
    enum Role: Equatable {
        case stage
        case source(String)
        case target(WakeTarget)
    }

    var role: Role
    private static let anchors = NSHashTable<WakeAnchorView>.weakObjects()

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        #if os(iOS)
        isUserInteractionEnabled = false
        #else
        wantsLayer = true
        #endif
        Self.anchors.add(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    static func all(in window: AnyObject) -> [WakeAnchorView] { anchors.allObjects.filter { $0.window === window } }

    /// 窗口最底下那一层：Mac 是窗口外框的层（工具栏与内容都在它下面），iOS 是窗口的层。
    #if os(iOS)
    static func rootLayer(of window: UIWindow) -> CALayer? { window.layer }
    #else
    static func rootLayer(of window: NSWindow) -> CALayer? { window.contentView?.superview?.layer }
    #endif

    /// 在 `root` 里看得见的那块：沿层树往上换算，被裁掉、藏起或透明的祖先让它不算在屏上。
    func frame(in root: CALayer) -> CGRect? {
        #if os(iOS)
        var current = layer
        #else
        guard var current = layer else { return nil }
        #endif
        var rect = current.bounds
        while let parent = current.superlayer {
            guard !current.isHidden, current.opacity > 0.01 else { return nil }
            rect = current.convert(rect, to: parent)
            if parent.masksToBounds || parent === root { rect = rect.intersection(parent.bounds) }
            guard !rect.isEmpty else { return nil }
            if parent === root { return rect }
            current = parent
        }
        return nil
    }
}

#if os(iOS)
typealias WakeAnchorBase = UIView

extension WakeAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> WakeAnchorView { WakeAnchorView(role: role) }
    func updateUIView(_ view: WakeAnchorView, context: Context) { view.role = role }
}

extension CueWakeStage.Probe: UIViewRepresentable {
    func makeUIView(context: Context) -> WakeAnchorView { make() }
    func updateUIView(_ view: WakeAnchorView, context: Context) { stage.color = color.resolve(in: context.environment).cgColor }
}
#else
typealias WakeAnchorBase = NSView

extension WakeAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> WakeAnchorView { WakeAnchorView(role: role) }
    func updateNSView(_ view: WakeAnchorView, context: Context) { view.role = role }
}

extension CueWakeStage.Probe: NSViewRepresentable {
    func makeNSView(context: Context) -> WakeAnchorView { make() }
    func updateNSView(_ view: WakeAnchorView, context: Context) { stage.color = color.resolve(in: context.environment).cgColor }
}
#endif

/// 一次叫醒的画（样子与时长见 `CueWakeStage`）：在窗口根层最上面铺一层画布，所有动画一次交给 Core Animation，全部播完画布拿掉。
/// 画布上每一层的模型值都是透明的：动画之前、之后都看不见，只在动画里出现。
struct WakeFlight {
    let color: CGColor
    let reduceMotion: Bool

    /// 一次最多飞几道。
    static let most = 3
    /// 相邻两道起飞的间隔。
    private static let stagger = 0.09
    /// 起飞那圈环外扩之后多久光离开。
    private static let liftoff = 0.05
    /// 光的直径。
    private static let head: CGFloat = 7
    /// 终点不在屏上时光升起多高。
    private static let drift: CGFloat = 24
    /// 先加速、后长长地减速：落进头像时已经很慢。
    private static let glide = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    static func distance(_ a: CGPoint, _ b: CGPoint?) -> CGFloat {
        guard let b else { return 0 }
        return hypot(a.x - b.x, a.y - b.y)
    }

    func play(from sources: [CGPoint], to target: CGRect?, in root: CALayer) {
        guard !sources.isEmpty || target != nil else { return }
        let canvas = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { canvas.removeFromSuperlayer() }
        canvas.frame = root.bounds
        canvas.zPosition = 10_000
        root.addSublayer(canvas)
        let scene = Scene(canvas: canvas, color: color, now: canvas.convertTime(CACurrentMediaTime(), from: nil), up: Self.up(in: root))
        if reduceMotion {
            if let target { scene.glow(ring: target) }
            for source in sources { scene.glow(dot: source) }
        } else {
            for (index, source) in sources.enumerated() {
                let start = Double(index) * Self.stagger
                scene.depart(at: source, delay: start)
                if let target {
                    let duration = scene.fly(from: source, to: target.center, delay: start + Self.liftoff)
                    // 光还差最后一点到时环就亮：落点与亮起连成一下
                    scene.land(on: target, delay: start + Self.liftoff + duration * 0.9)
                } else {
                    scene.drift(from: source, delay: start + Self.liftoff)
                }
            }
            if sources.isEmpty, let target { scene.land(on: target, delay: 0) }
        }
        CATransaction.commit()
    }

    /// 屏幕上的"上"在这层坐标里是 y 的哪个方向（iOS 的层 y 朝下；Mac 的层默认 y 朝上）。
    private static func up(in root: CALayer) -> CGFloat {
        #if os(iOS)
        -1
        #else
        root.contentsAreFlipped() ? -1 : 1
        #endif
    }

    private struct Scene {
        let canvas: CALayer
        let color: CGColor
        let now: CFTimeInterval
        let up: CGFloat

        /// 起飞：状态标外一圈细环外扩淡去。
        func depart(at point: CGPoint, delay: Double) {
            let ring = circle(at: point, radius: 6, line: 2)
            animate(ring, delay: delay, duration: 0.45, timing: WakeFlight.easeOut, [
                Self.keyframes("transform.scale", [0.8, 2.4]), Self.keyframes("opacity", [1, 0]),
            ])
        }

        /// 沿弧飞到 `end`，返回飞了多久。弧向窗口的竖中线那边鼓：从侧栏、屏边起飞时弧在屏内；几乎横着飞时往上鼓。
        func fly(from start: CGPoint, to end: CGPoint, delay: Double) -> Double {
            let length = WakeFlight.distance(start, end)
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            var normal = CGPoint(x: -(end.y - start.y) / max(length, 1), y: (end.x - start.x) / max(length, 1))
            let outward = abs(normal.x) < 0.2 ? normal.y * up < 0 : normal.x * (canvas.bounds.midX - mid.x) < 0
            if outward { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let bend = length * 0.28
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend))
            let duration = min(max(0.42 + Double(length) / 1800, 0.42), 0.72)
            streak(path, delay: delay, duration: duration, timing: WakeFlight.glide)
            return duration
        }

        /// 终点不在屏上：从状态标升起一小段淡去。
        func drift(from start: CGPoint, delay: Double) {
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(
                to: CGPoint(x: start.x + 6, y: start.y + up * WakeFlight.drift),
                control: CGPoint(x: start.x, y: start.y + up * WakeFlight.drift * 0.6))
            streak(path, delay: delay, duration: 0.55, timing: WakeFlight.easeOut, fades: true)
        }

        /// 一道光加它的尾巴：尾巴是同一条弧上的描边，终点跟着光走、起点晚一点出发、到终点时追上——尾巴越飞越短，落下时被头像收进去。
        /// 三层叠出由亮到暗的尾巴：短而亮的芯、长而淡的身子、宽而很淡的光晕（描边上不能铺沿着弧走的渐变）。
        private func streak(_ path: CGPath, delay: Double, duration: Double, timing: CAMediaTimingFunction, fades: Bool = false) {
            for (width, alpha, lag) in [(CGFloat(8), 0.12, 0.14), (2.5, 0.3, 0.3), (2, 0.9, 0.12)] {
                let trail = CAShapeLayer()
                trail.frame = canvas.bounds
                trail.path = path
                trail.fillColor = nil
                trail.strokeColor = color
                trail.lineWidth = width
                trail.lineCap = .round
                trail.opacity = 0
                canvas.addSublayer(trail)
                animate(trail, delay: delay, duration: duration, timing: timing, [
                    Self.keyframes("strokeEnd", [0, 1]),
                    Self.keyframes("strokeStart", [0, 0, 1], times: [0, NSNumber(value: lag), 1]),
                    Self.keyframes("opacity", [alpha, alpha, 0], times: [0, fades ? 0.4 : 0.75, 1]),
                ])
            }
            let dot = CALayer()
            let side = WakeFlight.head
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.cornerRadius = side / 2
            dot.backgroundColor = color
            dot.shadowColor = color
            dot.shadowOpacity = 1
            dot.shadowRadius = side * 0.8
            dot.shadowOffset = .zero
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.opacity = 0
            canvas.addSublayer(dot)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            animate(dot, delay: delay, duration: duration, timing: timing, [
                move,
                Self.keyframes("transform.scale", [0.5, 1.15, 1, fades ? 0.6 : 0.4], times: [0, 0.2, 0.85, 1]),
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.12, fades ? 0.5 : 0.88, 1]),
            ])
        }

        /// 落下：头像的环亮起（带一圈光晕），停一下再外扩到 1.6 倍淡去；稍后一圈细的涟漪扩得更远。不盖住它的脸。
        func land(on target: CGRect, delay: Double) {
            let (radius, line) = Self.ring(of: target)
            animate(circle(at: target.center, radius: radius, line: line, glows: true), delay: delay, duration: 0.7, [
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.12, 0.3, 1], timing: WakeFlight.easeOut),
                Self.keyframes("transform.scale", [1, 1, 1, 1.6], times: [0, 0.12, 0.3, 1], timing: WakeFlight.easeOut),
            ])
            animate(circle(at: target.center, radius: radius, line: max(1, line / 2)), delay: delay + 0.12, duration: 0.75, timing: WakeFlight.easeOut, [
                Self.keyframes("opacity", [0.7, 0]), Self.keyframes("transform.scale", [1, 2.1]),
            ])
        }

        /// 减弱动态效果：头像的环原地淡入高亮再淡出。
        func glow(ring target: CGRect) {
            let (radius, line) = Self.ring(of: target)
            animate(circle(at: target.center, radius: radius, line: line, glows: true), delay: 0, duration: 1, [Self.hold()])
        }

        /// 减弱动态效果：起点的状态标垫一层淡光，与头像同时亮、同时暗。
        func glow(dot point: CGPoint) {
            animate(circle(at: point, radius: 9, fill: 0.3), delay: 0, duration: 1, [Self.hold()])
        }

        private static func hold() -> CAAnimation {
            keyframes("opacity", [0, 1, 1, 0], times: [0, 0.2, 0.55, 1], timing: CAMediaTimingFunction(name: .easeInEaseOut))
        }

        /// 头像外那圈环的半径与线宽（`CueAvatar`：环宽约是外框的 7%）。
        private static func ring(of target: CGRect) -> (radius: CGFloat, line: CGFloat) {
            let side = min(target.width, target.height)
            let line = max(1.5, side * 0.07)
            return (side / 2 - line / 2, line)
        }

        /// 以 `point` 为心的一个圆：给了线宽是描边（`glows` 时描边外带一圈同色的光晕），否则按 `fill` 的透明度填色。
        private func circle(at point: CGPoint, radius: CGFloat, line: CGFloat? = nil, fill: CGFloat = 0, glows: Bool = false) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            shape.position = point
            shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
            if let line {
                shape.fillColor = nil
                shape.strokeColor = color
                shape.lineWidth = line
                if glows, let path = shape.path {
                    // 给出光晕的形状：不让渲染服务每帧从内容里另算一遍
                    shape.shadowPath = path.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 0)
                    shape.shadowColor = color
                    shape.shadowOpacity = 0.9
                    shape.shadowRadius = line * 1.6
                    shape.shadowOffset = .zero
                }
            } else {
                shape.fillColor = color.copy(alpha: color.alpha * fill)
            }
            shape.opacity = 0
            canvas.addSublayer(shape)
            return shape
        }

        /// 一组动画在 `delay` 之后开始；之前之后都是层的模型值（透明）。
        private func animate(_ layer: CALayer, delay: Double, duration: Double, timing: CAMediaTimingFunction? = nil, _ animations: [CAAnimation]) {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.beginTime = now + delay
            group.fillMode = .backwards
            group.timingFunction = timing
            layer.add(group, forKey: nil)
        }

        private static func keyframes(_ key: String, _ values: [Double], times: [NSNumber]? = nil, timing: CAMediaTimingFunction? = nil) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times
            if let timing { animation.timingFunctions = Array(repeating: timing, count: values.count - 1) }
            return animation
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
