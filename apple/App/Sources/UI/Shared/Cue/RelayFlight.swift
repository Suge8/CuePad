import QuartzCore
import SwiftUI

/// 画布上每一层的模型值都是透明的：动画之前、之后都看不见，只在动画里出现。
struct RelayFlight {
    let color: CGColor
    let reduceMotion: Bool

    static let most = 3
    private static let stagger = 0.09
    private static let liftoff = 0.08
    /// 头像那颗点亮起之后多久小环离开（交给）：先看清是 Cue 发出的。
    private static let release = 0.16
    private static let drift: CGFloat = 24

    static func distance(_ a: CGPoint, _ b: CGPoint?) -> CGFloat {
        guard let b else { return 0 }
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// 会话那头的一处：在根层里的位置（光飞向这里）与锚自己的层（接住的那几圈画在锚上：落点之后挪了——页头随换句重新居中、
    /// 列表重排——光圈跟着它走，也压在它后面的字底下，不盖住"+N"）。锚的层随视图的动画移动由渲染服务插值，App 进程不逐帧参与。
    struct Landing {
        let point: CGPoint
        let host: CALayer?
    }

    /// 叫醒：起点到光落进头像右下那颗点（点亮、小人醒，`CueWatch` 照它挂闸）一共多久。第一道光：起飞环外扩之后起飞，固定时长飞到点。
    static var wakeLanding: Double { liftoff + Scene.inboundArrival }
    static var launchLanding: Double { Scene.inboundArrival }

    /// 事件起点只映射一次 CA 时钟，各层沿用这个绝对起点，晚挂上的层从中途画起。
    func play(_ direction: CueFlight.Direction, cue: CGRect?, ends: [Landing], in root: CALayer, since: Date, landed: @escaping (Int) -> Void) {
        guard !ends.isEmpty || cue != nil else { return }
        stage(in: root, since: since) { scene in
            if reduceMotion {
                // 叫醒的那一下落在到点那一刻，与头像换的同一刻
                let at = direction == .wake ? Self.wakeLanding : 0
                if let cue { scene.glow(dot: scene.dot(of: cue), delay: at) }
                for end in ends { scene.glow(dot: end.point, delay: at) }
                ends.indices.forEach(landed)
            } else {
                switch direction {
                case .wake: wake(scene, from: ends.map(\.point), to: cue)
                case .relay: relay(scene, from: cue, to: ends, landed: landed)
                }
            }
        }
    }

    /// 机头处（`head`，根层坐标）当场起飞——满大、不透明，不在钮上外扩起飞环、也不从半大淡入：钮在这一刻换成发送中，起飞环与淡入的光叠在正飞走的飞机上，录屏里是一团糊。
    func launch(from head: CGPoint, to cue: CGRect?, in root: CALayer, since: Date) {
        stage(in: root, since: since) { scene in
            if reduceMotion {
                if let cue { scene.glow(dot: scene.dot(of: cue), delay: Self.launchLanding) }
            } else if let cue {
                scene.land(from: head, on: cue, delay: 0, launches: true)
            } else {
                scene.drift(from: head, rise: scene.up * Self.drift, head: .dot, delay: 0, launches: true)
            }
        }
    }

    private func stage(in root: CALayer, since: Date, _ draw: (Scene) -> Void) {
        let origin = CACurrentMediaTime() + since.timeIntervalSinceNow
        let canvas = CALayer(), pads = Scene.Pads()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            canvas.removeFromSuperlayer()
            pads.layers.forEach { $0.removeFromSuperlayer() }
        }
        canvas.frame = root.bounds
        canvas.zPosition = 10_000
        root.addSublayer(canvas)
        draw(Scene(origin: origin, canvas: canvas, pads: pads, color: color, up: Self.up(in: root)))
        CATransaction.commit()
    }

    private func wake(_ scene: Scene, from sources: [CGPoint], to target: CGRect?) {
        for (index, source) in sources.enumerated() {
            let start = Double(index) * Self.stagger
            scene.depart(at: source, delay: start)
            if let target {
                scene.land(from: source, on: target, delay: start + Self.liftoff)
            } else {
                scene.drift(from: source, rise: scene.up * Self.drift, head: .dot, delay: start + Self.liftoff)
            }
        }
        if sources.isEmpty, let target { scene.light(dot: scene.dot(of: target), avatar: target, delay: Self.wakeLanding) }
    }

    private func relay(_ scene: Scene, from source: CGRect?, to targets: [Landing], landed: @escaping (Int) -> Void) {
        guard let source else {
            for (index, target) in targets.enumerated() {
                scene.receive(at: target, delay: Double(index) * Self.stagger) { landed(index) }
            }
            return
        }
        let dot = scene.dot(of: source)
        scene.light(dot: dot, avatar: source, delay: 0)
        for (index, target) in targets.enumerated() {
            let start = Self.release + Double(index) * Self.stagger
            let arrival = scene.fly(from: dot, to: target.point, head: .ring, delay: start)
            scene.receive(at: target, delay: start + arrival) { landed(index) }
        }
        if targets.isEmpty {
            let inward: CGFloat = scene.canvas.bounds.midY > source.midY ? 1 : -1
            scene.drift(from: dot, rise: inward * Self.drift * 1.5, head: .ring, delay: Self.release)
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
