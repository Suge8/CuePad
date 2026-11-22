import QuartzCore
import SwiftUI

/// 开门：每次冷启动，窗口先是启动屏那一幕（图标的墨色、正中站着 Cue，iOS 的启动屏就是它：`LaunchBackground`、`LaunchCue`），
/// 两者与这里盖的第一帧要一模一样，接缝才看不出。模拟器的 splashboardd 把资源目录缓存在内存里、重装也不重读（装的路径不变）：
/// 改了这两样，杀掉它（launchd 自己再起）才看得到新的启动屏，不然一直是旧色。
/// Cue 页的天空第一次画好后，从 Cue 腰上那只环的位置张开一扇门：环由扁转圆一路撑到屏外，门里的天空由粗格子收拢到平时的细格子，
/// 整个窗口从近处退回原位，Cue 顺势落回它住的地方（空着的 Cue 页落在云上，否则落进头像，`relaySpot(cue:)`）。
/// 一个进程只放一次：回前台、开第二个窗口都不放。降低动态效果时墨色直接淡掉。
/// 画法同接力（`CueRelayStage`）：整块交给 Core Animation，盖在窗口最底层之上；冷启动时主线程正忙，逐帧不经 App 进程才不掉帧。
/// 环、门、镜头、小人都取自同一条时间线（`Door`），采成关键帧一次交出去。
@Observable
final class CueOpening {
    static let shared = CueOpening()

    enum Phase: Equatable {
        case shut
        case opening(landing: CueSpot?, grain: Int)
        case open

        /// 天空的格子是平时的几倍：门缝里先是粗格子，门开到几成就细一档。
        var grain: Int {
            switch self {
            case .shut: Door.grains[0]
            case .opening(_, let grain): grain
            case .open: 1
            }
        }

        /// 小人还没落下时它要落的那处藏着；门开之前哪处都藏着（落点等门开那一刻才量）。
        func hides(_ spot: CueSpot) -> Bool {
            switch self {
            case .shut: true
            case .opening(let landing, _): landing == spot
            case .open: false
            }
        }
    }

    private(set) var phase = Phase.shut
    @ObservationIgnored private var began = false
    @ObservationIgnored private var skyDrawn = false
    @ObservationIgnored private var waiting: CheckedContinuation<Void, Never>?

    func drewSky() {
        skyDrawn = true
        release()
    }

    private func release() {
        waiting?.resume()
        waiting = nil
    }

    fileprivate func play(in window: AnyObject, root: CALayer, world: CALayer?, ink: CGColor, ring: [CGColor], cue: CGImage, reduceMotion: Bool) {
        guard !began else { return }
        began = true
        if reduceMotion { phase = .open }
        let up = RelayFlight.up(in: root)
        let curtain = Curtain(root: root, world: world, ink: ink, ring: ring, cue: cue, at: Door.start(in: root.bounds))
        Task {
            let clock = ContinuousClock(), start = clock.now
            await sky(by: start + Door.patience)
            try? await clock.sleep(until: start + Door.dwell)
            await NextFrame.drawn()
            guard !reduceMotion else { return await curtain.fade() }
            let landing = Self.landing(in: window, root: root)
            let door = Door(bounds: root.bounds, up: up, landing: landing)
            phase = .opening(landing: landing?.spot, grain: Door.grains[0])
            let steps = Task {
                let opened = clock.now
                for (index, at) in door.steps.enumerated() {
                    guard (try? await clock.sleep(until: opened + .seconds(at))) != nil else { return }
                    phase = .opening(landing: landing?.spot, grain: Door.grains[index + 1])
                }
            }
            await curtain.open(door)
            steps.cancel()
            phase = .open
            await NextFrame.drawn()
            curtain.remove()
        }
    }

    private func sky(by deadline: ContinuousClock.Instant) async {
        guard !skyDrawn else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
            Task {
                try? await Task.sleep(until: deadline)
                release()
            }
        }
    }

    /// 落在哪：云上的小人在就落它身上，否则落进看得见的那个头像（按图的宽高比套进头像那一圈）。
    private static func landing(in window: AnyObject, root: CALayer) -> Door.Landing? {
        let spots = RelayAnchorView.all(in: window).compactMap { anchor -> (spot: CueSpot, frame: CGRect)? in
            guard case .cue(let spot) = anchor.role, let frame = anchor.frame(in: root) else { return nil }
            return (spot, frame)
        }
        guard let (spot, frame) = spots.max(by: { $0.spot.rawValue < $1.spot.rawValue }) else { return nil }
        if spot == .perch { return Door.Landing(spot: spot, frame: frame, lift: 34) }
        let height = frame.width * Door.cue.height / Door.cue.width
        return Door.Landing(spot: spot, frame: CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height), lift: 18)
    }
}

/// 开门的时间线：尺寸都按启动屏上那个 Cue 量（环在它腰上），时间都按门开的进度 `t`（0…1）。
private struct Door {
    struct Landing {
        let spot: CueSpot?
        let frame: CGRect
        let lift: CGFloat
    }

    struct Frame {
        let hole: CGRect
        let ring: CGRect
        let tube: CGFloat
        let zoom: CGFloat
        let cue: CGRect
    }

    /// 启动屏上那个 Cue 的大小，同 `LaunchCue` 图（@3x 450 像素宽）。
    static let cue = CGSize(width: 150, height: 142.5)
    static let duration = 1.15
    /// 墨色至少停这么久：iOS 的图标还在放大成启动屏，Mac 的窗口刚出来，先看清是 Cue 再开门。
    static let dwell = Duration.milliseconds(350)
    /// 天空等不到就不等了（Cue 栏收着时它可能不画）。
    static let patience = Duration.seconds(1)
    static let grains = [5, 3, 2, 1]
    private static let thresholds = [0.2, 0.4, 0.62]
    private static let samples = 72
    private static let ringAt = (y: 0.6, rx: 0.43, ry: 0.13, tube: 0.075)
    private static let finalTube: CGFloat = 48
    private static let reach: CGFloat = 110
    private static let zoom: CGFloat = 0.26

    let bounds: CGRect
    let up: CGFloat
    let landing: Landing?

    static func start(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - cue.width / 2, y: bounds.midY - cue.height / 2, width: cue.width, height: cue.height)
    }

    var start: CGRect { Self.start(in: bounds) }

    var center: CGPoint {
        CGPoint(x: start.midX, y: start.midY - up * (Self.ringAt.y - 0.5) * start.height)
    }

    /// 门开到 `thresholds` 那几成的时刻（秒）：天空细一档。
    var steps: [Double] {
        Self.thresholds.map { threshold in
            let t = (0...Self.samples).map { Double($0) / Double(Self.samples) }.first { Self.open($0) >= threshold } ?? 1
            return t * Self.duration
        }
    }

    var frames: [Frame] { (0...Self.samples).map { at(Double($0) / Double(Self.samples)) } }

    func at(_ t: Double) -> Frame {
        let width = start.width, e = CGFloat(Self.open(t))
        let far = hypot(max(center.x - bounds.minX, bounds.maxX - center.x), max(center.y - bounds.minY, bounds.maxY - center.y)) + Self.reach
        let rx0 = width * Self.ringAt.rx, ry0 = width * Self.ringAt.ry, tube0 = width * Self.ringAt.tube
        let rx = rx0 + (far - rx0) * e
        let ry = ry0 + (rx - ry0) * Self.out3(min(1, t / 0.5))
        let tube = tube0 + (Self.finalTube - tube0) * Self.out3(min(1, t / 0.7))
        let ix = max(0, rx - tube / 2 + 1), iy = max(0, ry - tube / 2 + 1)
        let f = Self.inOut3(min(1, max(0, (t - 0.16) / 0.78)))
        let to = landing?.frame ?? start
        var cue = CGRect(
            x: start.minX + (to.minX - start.minX) * f, y: start.minY + (to.minY - start.minY) * f,
            width: start.width + (to.width - start.width) * f, height: start.height + (to.height - start.height) * f)
        cue.origin.y += up * sin(.pi * f) * (landing?.lift ?? 0)
        return Frame(
            hole: CGRect(x: center.x - ix, y: center.y - iy, width: 2 * ix, height: 2 * iy),
            ring: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry),
            tube: tube, zoom: 1 + Self.zoom * (1 - e), cue: cue)
    }

    /// 门开的快慢：起手慢、中段猛地撑开、收尾很长（cubic-bezier(.66, 0, .14, 1)）。
    private static func open(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.66, 0.0, 0.14, 1.0)
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<26 {
            u = (lo + hi) / 2
            let x = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            if x < t { lo = u } else { hi = u }
        }
        return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }

    private static func out3(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - t, 3)) }

    private static func inOut3(_ t: Double) -> CGFloat { CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2) }
}

/// 盖在窗口上的那几层：墨色（挖一个门洞）、门洞里的投影与内沿的光、环、小人。
private final class Curtain {
    private let canvas = CALayer()
    private let ink = CAShapeLayer()
    private let depth = CAShapeLayer()
    private let depthMask = CAShapeLayer()
    private let lip = CAShapeLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let figure = CALayer()
    private let world: CALayer?

    private static let rimStops: [NSNumber] = [0, 0.2, 0.48, 0.72, 1]
    private static let shadowBlur: CGFloat = 14
    /// 环的高光从左上斜着照下来（CSS 的 165°）。
    private static let light = CGVector(dx: sin(165 * Double.pi / 180), dy: -cos(165 * Double.pi / 180))

    init(root: CALayer, world: CALayer?, ink color: CGColor, ring: [CGColor], cue: CGImage, at start: CGRect) {
        self.world = world
        let bounds = root.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        canvas.zPosition = 10_001
        for layer in [ink, depth, depthMask, lip, rimMask] { layer.frame = bounds }
        rim.frame = bounds
        ink.fillColor = color
        ink.path = CGPath(rect: bounds, transform: nil)
        depth.fillColor = CGColor(gray: 0, alpha: 1)
        depth.shadowColor = CGColor(gray: 0, alpha: 1)
        depth.shadowOpacity = 0.5
        depth.shadowRadius = Self.shadowBlur
        depth.mask = depthMask
        depth.isHidden = true
        lip.fillColor = nil
        lip.strokeColor = CGColor(gray: 1, alpha: 0.16)
        lip.lineWidth = 1.5
        rim.colors = ring
        rim.locations = Self.rimStops
        rim.mask = rimMask
        rim.isHidden = true
        figure.contents = cue
        figure.contentsGravity = .resizeAspect
        figure.frame = start
        canvas.addSublayer(ink)
        canvas.addSublayer(depth)
        canvas.addSublayer(lip)
        canvas.addSublayer(rim)
        canvas.addSublayer(figure)
        root.addSublayer(canvas)
        CATransaction.commit()
    }

    func open(_ door: Door) async {
        let frames = door.frames, bounds = canvas.bounds, up = door.up
        let bottom = CGPoint(x: 0.5, y: up < 0 ? 1 : 0)
        await withCheckedContinuation { done in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { done.resume() }
            depth.isHidden = false
            rim.isHidden = false
            depth.shadowOffset = CGSize(width: 0, height: -up * 12)
            figure.anchorPoint = bottom
            let frame = frames.last!
            figure.bounds = CGRect(origin: .zero, size: frame.cue.size)
            figure.position = CGPoint(x: frame.cue.midX, y: up < 0 ? frame.cue.maxY : frame.cue.minY)
            let holed = frames.map { Self.holed(bounds, by: $0.hole) }
            add(ink, "path", holed)
            add(depth, "path", holed)
            add(depth, "shadowPath", holed)
            add(depthMask, "path", frames.map { CGPath(ellipseIn: $0.hole, transform: nil) })
            add(lip, "path", frames.map { CGPath(ellipseIn: $0.hole, transform: nil) })
            add(rimMask, "path", frames.map { Self.ring($0) })
            let lit = frames.map { Self.lit($0, in: bounds, up: up) }
            add(rim, "startPoint", lit.map { Self.value($0.0) })
            add(rim, "endPoint", lit.map { Self.value($0.1) })
            add(figure, "bounds.size", frames.map { Self.value($0.cue.size) })
            add(figure, "position", frames.map { Self.value(CGPoint(x: $0.cue.midX, y: up < 0 ? $0.cue.maxY : $0.cue.minY)) })
            if door.landing == nil { add(figure, "opacity", frames.indices.map { 1 - Double($0) / Double(frames.count - 1) }) }
            if let world {
                let center = canvas.convert(door.center, to: world)
                let anchor = CGPoint(x: world.bounds.minX + world.anchorPoint.x * world.bounds.width, y: world.bounds.minY + world.anchorPoint.y * world.bounds.height)
                let shift = CGPoint(x: center.x - anchor.x, y: center.y - anchor.y)
                add(world, "transform", frames.map { frame in
                    var zoom = CATransform3DMakeTranslation(-shift.x, -shift.y, 0)
                    zoom = CATransform3DConcat(zoom, CATransform3DMakeScale(frame.zoom, frame.zoom, 1))
                    return NSValue(caTransform3D: CATransform3DConcat(zoom, CATransform3DMakeTranslation(shift.x, shift.y, 0)))
                }, holds: false)
            }
            if door.landing != nil {
                let settle = CASpringAnimation(keyPath: "transform")
                settle.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(1.08, 0.88, 1))
                settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                settle.stiffness = 320
                settle.damping = 14
                settle.duration = 0.55
                settle.beginTime = figure.convertTime(CACurrentMediaTime(), from: nil) + Door.duration * 0.94
                figure.add(settle, forKey: "settle")
            }
            CATransaction.commit()
        }
    }

    func fade() async {
        await withCheckedContinuation { done in
            CATransaction.begin()
            CATransaction.setCompletionBlock { done.resume() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.25
            canvas.opacity = 0
            canvas.add(fade, forKey: "fade")
            CATransaction.commit()
        }
        remove()
    }

    func remove() { canvas.removeFromSuperlayer() }

    private func add(_ layer: CALayer, _ keyPath: String, _ values: [Any], holds: Bool = true) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = Door.duration
        animation.calculationMode = .linear
        if holds {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: keyPath)
    }

    #if os(iOS)
    private static func value(_ point: CGPoint) -> NSValue { NSValue(cgPoint: point) }
    private static func value(_ size: CGSize) -> NSValue { NSValue(cgSize: size) }
    #else
    private static func value(_ point: CGPoint) -> NSValue { NSValue(point: point) }
    private static func value(_ size: CGSize) -> NSValue { NSValue(size: size) }
    #endif

    /// 整块墨色挖掉门洞。门洞反着绕：投影的路径只认非零绕数，同向绕就填满、挖不出洞。
    private static func holed(_ bounds: CGRect, by hole: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: hole, transform: CGAffineTransform(translationX: 2 * hole.midX, y: 0).scaledBy(x: -1, y: 1))
        return path
    }

    private static func ring(_ frame: Door.Frame) -> CGPath {
        let path = CGMutablePath()
        let half = frame.tube / 2
        path.addEllipse(in: frame.ring.insetBy(dx: -half, dy: -half))
        path.addEllipse(in: frame.ring.insetBy(dx: half, dy: half), transform: CGAffineTransform(translationX: 2 * frame.ring.midX, y: 0).scaledBy(x: -1, y: 1))
        return path
    }

    /// 环的明暗按它自己的外框铺：渐变层铺满整窗，起止点随环换算成整窗的单位坐标。
    private static func lit(_ frame: Door.Frame, in bounds: CGRect, up: CGFloat) -> (CGPoint, CGPoint) {
        let box = frame.ring.insetBy(dx: -frame.tube / 2, dy: -frame.tube / 2)
        let dx = light.dx, dy = light.dy * -up
        let half = (abs(box.width * dx) + abs(box.height * dy)) / 2
        let unit = { (x: CGFloat, y: CGFloat) in CGPoint(x: (x - bounds.minX) / bounds.width, y: (y - bounds.minY) / bounds.height) }
        return (unit(box.midX - dx * half, box.midY - dy * half), unit(box.midX + dx * half, box.midY + dy * half))
    }
}

extension View {
    /// 挂在窗口的根上：第一次进窗口就把墨色盖上（与启动屏同一帧接上），之后照 `CueOpening` 开门。
    func cueOpening() -> some View { modifier(OpeningStage()) }
}

private struct OpeningStage: ViewModifier {
    func body(content: Content) -> some View {
        content.background { OpeningProbe() }.debugSettling(CueOpening.shared.phase != .open)
    }
}

private struct OpeningProbe {
    final class Probe: RelayAnchorBase {
        var reduceMotion = false
        var ring: [CGColor] = []

        #if os(iOS)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            let ink = UIColor(named: "LaunchBackground")!.resolvedColor(with: window.windowScene!.screen.traitCollection).cgColor
            CueOpening.shared.play(
                in: window, root: window.layer, world: window.rootViewController?.view.layer, ink: ink, ring: ring,
                cue: UIImage(named: "cue-stage-idle")!.cgImage!, reduceMotion: reduceMotion)
        }
        #else
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let root = RelayAnchorView.rootLayer(of: window) else { return }
            var ink = CGColor(gray: 0, alpha: 1)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor(named: "LaunchBackground")!.cgColor }
            CueOpening.shared.play(
                in: window, root: root, world: window.contentView?.layer, ink: ink, ring: ring,
                cue: NSImage(named: "cue-stage-idle")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!, reduceMotion: reduceMotion)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        #endif
    }
}

#if os(iOS)
extension OpeningProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.reduceMotion = context.environment.accessibilityReduceMotion
        probe.ring = context.environment.palette.ringTube.map { $0.resolve(in: context.environment).cgColor }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}
}
#else
extension OpeningProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.reduceMotion = context.environment.accessibilityReduceMotion
        probe.ring = context.environment.palette.ringTube.map { $0.resolve(in: context.environment).cgColor }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}
}
#endif
