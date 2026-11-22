import QuartzCore
import SwiftUI

struct RelayFlight {
    let color: CGColor
    let reduceMotion: Bool

    static let most = 3
    private static let stagger = 0.09
    private static let liftoff = 0.08
    private static let release = 0.16
    private static let drift: CGFloat = 24

    static func distance(_ a: CGPoint, _ b: CGPoint?) -> CGFloat {
        guard let b else { return 0 }
        return hypot(a.x - b.x, a.y - b.y)
    }

    struct Landing {
        let point: CGPoint
        let host: CALayer?
    }

    static var wakeLanding: Double { liftoff + Scene.inboundArrival }
    static var launchLanding: Double { Scene.inboundArrival }

    func play(_ direction: CueFlight.Direction, cue: CGRect?, ends: [Landing], in root: CALayer, since: Date, landed: @escaping (Int) -> Void) {
        guard !ends.isEmpty || cue != nil else { return }
        stage(in: root, since: since) { scene in
            if reduceMotion {
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
