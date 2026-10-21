import CueStore
import QuartzCore
import SwiftUI

/// 一次接力的画（样子与时长见 `CueRelayStage`）：在窗口根层最上面铺一层画布，所有动画一次交给 Core Animation，全部播完画布拿掉。
/// 画布上每一层的模型值都是透明的：动画之前、之后都看不见，只在动画里出现。
struct RelayFlight {
    let color: CGColor
    let reduceMotion: Bool

    /// 一次最多飞几道。
    static let most = 3
    /// 相邻两道起飞的间隔。
    private static let stagger = 0.09
    /// 起飞那圈环外扩之后多久光离开状态标（叫醒）。
    private static let liftoff = 0.08
    /// 头像的环亮起之后多久小环离开头像（交给）：先看清是 Cue 发出的。
    private static let release = 0.16
    /// 飞着的那颗点（叫醒）与那个小环（交给）的直径。
    static let head: CGFloat = 8
    static let ring: CGFloat = 11
    /// 另一头不在屏上时光飘多远。
    private static let drift: CGFloat = 24
    /// 先加速、后长长地减速：落下时已经很慢。
    static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.22, 1)
    static let flight = 0.78...1.08
    static let pointsPerSecond = 1800.0
    static let bend: CGFloat = 48
    static let mostBend: CGFloat = 160
    private static let arrival = 0.92
    static let ripple = 0.14
    static let depart = 0.58
    static let reception = 0.82
    static let avatar = 0.78
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    static func distance(_ a: CGPoint, _ b: CGPoint?) -> CGFloat {
        guard let b else { return 0 }
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// `cue` 是头像在屏上的那块，`ends` 是会话那头在屏上的几处（都可能不在）。交给的光落到第几处时调 `landed`（落点那圈环开始扩的那一刻）。
    func play(_ direction: CueFlight.Direction, cue: CGRect?, ends: [CGPoint], in root: CALayer, landed: @escaping (Int) -> Void) {
        guard !ends.isEmpty || cue != nil else { return }
        stage(in: root) { scene in
            if reduceMotion {
                if let cue { scene.glow(ring: cue) }
                for end in ends { scene.glow(dot: end) }
                ends.indices.forEach(landed)
            } else {
                switch direction {
                case .wake: wake(scene, from: ends, to: cue)
                case .relay: relay(scene, from: cue, to: ends, landed: landed)
                }
            }
        }
    }

    /// 发出（输入框的发送钮 → Cue 的头像）：钮上纸飞机的机头就是那点光，从机头处（`head`，根层坐标）当场起飞——满大、不透明，
    /// 不在钮上外扩起飞环、也不从半大淡入：钮在这一刻换成发送中，起飞环与淡入的光叠在正飞走的飞机上，录屏里是一团糊。
    /// 落进头像同叫醒；头像不在屏上时往上飘一小段淡去。减弱动态效果：只有头像的环淡亮一下（起点的钮自己已换成发送中，不再压一层光）。
    func launch(from head: CGPoint, to cue: CGRect?, in root: CALayer) {
        stage(in: root) { scene in
            if reduceMotion {
                if let cue { scene.glow(ring: cue) }
            } else if let cue {
                let duration = scene.fly(from: head, to: cue.center, head: .dot, delay: 0, launches: true)
                scene.land(on: cue, delay: duration * Self.arrival)
            } else {
                scene.drift(from: head, rise: scene.up * Self.drift, head: .dot, delay: 0, launches: true)
            }
        }
    }

    /// 在窗口根层最上面铺一层画布交给 `draw` 画，所有动画一次提交给 Core Animation，播完画布拿掉。
    private func stage(in root: CALayer, _ draw: (Scene) -> Void) {
        let canvas = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { canvas.removeFromSuperlayer() }
        canvas.frame = root.bounds
        canvas.zPosition = 10_000
        root.addSublayer(canvas)
        draw(Scene(canvas: canvas, color: color, now: canvas.convertTime(CACurrentMediaTime(), from: nil), up: Self.up(in: root)))
        CATransaction.commit()
    }

    private func wake(_ scene: Scene, from sources: [CGPoint], to target: CGRect?) {
        for (index, source) in sources.enumerated() {
            let start = Double(index) * Self.stagger
            scene.depart(at: source, delay: start)
            if let target {
                let duration = scene.fly(from: source, to: target.center, head: .dot, delay: start + Self.liftoff)
                // 光还差最后一点到时环就亮：落点与亮起连成一下
                scene.land(on: target, delay: start + Self.liftoff + duration * Self.arrival)
            } else {
                scene.drift(from: source, rise: scene.up * Self.drift, head: .dot, delay: start + Self.liftoff)
            }
        }
        if sources.isEmpty, let target { scene.land(on: target, delay: 0) }
    }

    private func relay(_ scene: Scene, from source: CGRect?, to targets: [CGPoint], landed: @escaping (Int) -> Void) {
        guard let source else {
            for (index, target) in targets.enumerated() {
                scene.depart(at: target, delay: Double(index) * Self.stagger, fills: true) { landed(index) }
            }
            return
        }
        scene.send(from: source)
        for (index, target) in targets.enumerated() {
            let start = Self.release + Double(index) * Self.stagger
            let duration = scene.fly(from: source.center, to: target, head: .ring, delay: start)
            scene.depart(at: target, delay: start + duration * Self.arrival, fills: true) { landed(index) }
        }
        // 会话不在屏上：从头像朝窗口中间那侧的边上飘出一段（从页头往下、从窗口下沿的头像往上）——从脸的中心起飘，还没出头像就淡了
        if targets.isEmpty {
            let inward: CGFloat = scene.canvas.bounds.midY > source.midY ? 1 : -1
            let edge = CGPoint(x: source.midX, y: source.midY + inward * source.height / 2)
            scene.drift(from: edge, rise: inward * Self.drift * 1.5, head: .ring, delay: Self.release)
        }
    }

    /// 屏幕上的"上"在这层坐标里是 y 的哪个方向（iOS 的层 y 朝下；Mac 的层默认 y 朝上）。
    static func up(in root: CALayer) -> CGFloat {
        #if os(iOS)
        -1
        #else
        root.contentsAreFlipped() ? -1 : 1
        #endif
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
