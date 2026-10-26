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
    /// 头像那颗点亮起之后多久小环离开（交给）：先看清是 Cue 发出的。
    private static let release = 0.16
    /// 另一头不在屏上时光飘多远。
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
    /// 发出：送出到光落进那颗点多久（当场起飞，不先漾环）。
    static var launchLanding: Double { Scene.inboundArrival }

    /// `cue` 是头像在屏上的那块，`ends` 是会话那头在屏上的几处（都可能不在）。交给的光落到第几处时调 `landed`（落点那圈环开始扩的那一刻，新开的会话行这时淡出来）。
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

    /// 发出（输入框的发送钮 → Cue 的头像）：钮上纸飞机的机头就是那点光，从机头处（`head`，根层坐标）当场起飞——满大、不透明，
    /// 不在钮上外扩起飞环、也不从半大淡入：钮在这一刻换成发送中，起飞环与淡入的光叠在正飞走的飞机上，录屏里是一团糊。
    /// 落进头像右下那颗点同叫醒（固定时长，`launchLanding` 时点亮，头像同一刻露"在听"，`CueWatch.sent`）；头像不在屏上时往上飘一小段淡去。
    /// 减弱动态效果：只有那颗点在到点那一刻淡亮一下（起点的钮自己已换成发送中，不再压一层光）。
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

    /// 在窗口根层最上面铺一层画布交给 `draw` 画（挂在锚上的几圈另记在 `pads`），所有动画一次提交给 Core Animation，播完一并拿掉。
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

    /// 叫醒：光落进头像右下那颗点（光头到点那一刻那颗点亮起来，头像同一刻醒——那一刻由起点推出，`wakeLanding`），不在头像外画环。
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
        // 从头像右下那颗点发出：点先亮一下，小环再离开
        let dot = scene.dot(of: source)
        scene.light(dot: dot, avatar: source, delay: 0)
        for (index, target) in targets.enumerated() {
            let start = Self.release + Double(index) * Self.stagger
            let arrival = scene.fly(from: dot, to: target.point, head: .ring, delay: start)
            scene.receive(at: target, delay: start + arrival) { landed(index) }
        }
        // 会话不在屏上：从那颗点朝窗口中间那侧飘出一段（从页头往下、从窗口下沿的头像往上）
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
