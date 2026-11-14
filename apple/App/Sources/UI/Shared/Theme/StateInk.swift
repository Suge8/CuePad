import QuartzCore
import SwiftUI

/// 会话状态标里的那几根线：在想时是走着心跳的线，用工具时拧成扳手，压缩时是两块板夹着的弹簧，等子代理时是飘着的小机器人，
/// 在问时是气泡里一个问号，新回复是一封信，被打断时是拔开的插头，已结束时是月牙；空闲时收进中心、什么都不画。
/// 换状态是同一组线逐点变形过去（几何由 design/tools/ink/state_geometry.py 从符号的中线导出，每根同样点数），不换掉重画；
/// 不是线的状态（铃铛、出错的徽、纸飞机，`StateDot` 叠在上面）这组线收进中心。
/// 变形与常驻的动作都是 Core Animation、交给渲染服务（理由同 `LoopLayer`）；常驻动作只在 `loops` 时放，长时间挂着的几种隔几秒到十几秒才动一下（`InkBeat`）。
struct StateInk {
    let pose: InkPose
    let color: Color
    /// `LoopsPlay`：不放时停在静止的样子。
    let loops: Bool
    /// 减弱动态效果时为 false：换状态只交叉淡。
    let morphs: Bool

    final class Host: LoopHostBase {
        private let ink = CALayer()
        private let strands = (0..<InkPose.Shape.most).map { _ in Strand() }
        private var pose: InkPose?
        private var color: CGColor?
        private var loops = false

        #if os(iOS)
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            setUp()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            place()
        }

        private var root: CALayer { layer }
        private var displayScale: CGFloat { traitCollection.displayScale }
        #else
        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            setUp()
        }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            place()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var root: CALayer { layer! }
        private var displayScale: CGFloat { window?.backingScaleFactor ?? 2 }
        #endif

        required init?(coder: NSCoder) { fatalError() }

        private func setUp() {
            ink.bounds = Self.grid
            root.addSublayer(ink)
            for strand in strands {
                for layer in [strand.box, strand.base, strand.runner] as [CALayer] {
                    layer.bounds = Self.grid
                    layer.position = .zero
                }
                for shape in [strand.base, strand.runner] {
                    shape.fillColor = nil
                    shape.lineCap = .round
                    shape.lineJoin = .round
                    shape.lineWidth = 0
                    strand.box.addSublayer(shape)
                }
                // 走的那一截只有主线有：叠在别的线上，半透明的颜色会把那根描深一层
                strand.runner.isHidden = true
                ink.addSublayer(strand.box)
            }
        }

        /// 线在 24 格的坐标里画（原点在中心），整组按边长缩放：线宽、位移都按格写，尺寸变了不用重挂动画。
        /// 栅格化按缩放后的大小（`contentsScale`），放大了也不糊。
        private func place() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = min(root.bounds.width, root.bounds.height)
            let scale = side / Self.grid.width
            ink.position = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
            ink.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            for strand in strands {
                strand.base.contentsScale = displayScale * scale
                strand.runner.contentsScale = displayScale * scale
            }
            CATransaction.commit()
        }

        func show(_ pose: InkPose, color: CGColor?, loops: Bool, morphs: Bool) {
            guard pose != self.pose || color != self.color || loops != self.loops else { return }
            let (old, looped) = (self.pose, self.loops)
            (self.pose, self.color, self.loops) = (pose, color, loops)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if old?.shape != pose.shape {
                if old != nil, !morphs { ink.add(Self.crossfade(), forKey: "fade") }
                reshape(pose.shape, animated: old != nil && morphs)
            }
            if old?.life != pose.life || looped != loops {
                live(pose.life)
                // 换进一个不一直动的状态：变形落定时先动一下，不等下一次敲
                if old != nil, loops { beat(pose.life, delay: Motion.Ink.morph * 0.6) }
            }
            paint(animated: old != nil)
            CATransaction.commit()
        }

        /// 每根线换到新形状上：新形状里没有的那根收成一点、落在新主线上离它最近的地方；新冒出来的一根从旧主线上离它最近的一点长出来。
        private func reshape(_ shape: InkPose.Shape, animated: Bool) {
            let target = shape.strands
            let oldSpine = strands[0].points
            let newSpine = target.first.map(InkPose.points) ?? [.zero]
            for (index, strand) in strands.enumerated() {
                let to: (points: [CGPoint], width: CGFloat)
                if index < target.count {
                    to = (InkPose.points(target[index]), target[index].width)
                    if strand.width == 0, (strand.base.presentation()?.lineWidth ?? 0) < 0.01 {
                        strand.set(Self.parked(near: Self.middle(to.points), on: oldSpine), width: 0)
                    }
                } else {
                    let from = strand.width > 0 ? Self.middle(strand.points) : .zero
                    to = (Self.parked(near: from, on: newSpine), 0)
                }
                strand.morph(to: to.points, width: to.width, animated: animated)
            }
        }

        /// 常驻的动作与各层的静止值（亮度、跑的那一截）。在干活的几种一直动（`LoopLayer.Host.loop`）；其余由 `InkBeat` 隔几秒敲一下。
        private func live(_ life: InkPose.Life) {
            for layer in [ink] + strands.flatMap({ [$0.box, $0.runner] }) {
                for key in layer.animationKeys() ?? [] where ["life", "blink", "beat"].contains(key) { layer.removeAnimation(forKey: key) }
            }
            strands.forEach { $0.pivot(at: .zero) }
            let main = strands[0]
            main.runner.isHidden = !(life == .pulse && loops)
            main.runner.strokeStart = 0
            main.runner.strokeEnd = 0
            InkBeat.shared.leave(self)
            guard loops else { return }
            switch life {
            case .pulse:
                let head = CAKeyframeAnimation(keyPath: "strokeEnd")
                head.values = [0, 1, 1]
                head.keyTimes = [0, 0.78, 1]
                let tail = CAKeyframeAnimation(keyPath: "strokeStart")
                tail.values = [0, 0, 1]
                tail.keyTimes = [0, 0.32, 1]
                let walk = CAAnimationGroup()
                walk.animations = [head, tail]
                walk.duration = 1.4
                walk.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.55, 0.95)
                _ = LoopLayer.Host.loop(walk, on: main.runner, key: "life")
            case .twist:
                // 绕扳手头拧过去、带一点回弹，停一拍再拧
                main.pivot(at: CGPoint(x: 4, y: -4))
                _ = LoopLayer.Host.loop(Self.frames("transform.rotation.z", Self.degrees([(0, 0), (0.45, -24), (0.75, 5), (1, 0), (1.5, 0)])), on: main.box, key: "life")
            case .press:
                // 两块板往里一压、弹簧挤紧，松开时弹过一点再落定
                let push: [(Double, CGFloat)] = [(0, 0), (0.45, 2.6), (0.65, 2.6), (0.95, -0.5), (1.15, 0), (1.4, 0)]
                _ = LoopLayer.Host.loop(Self.frames("transform.scale.x", push.map { ($0.0, 1 - $0.1 * 0.145) }), on: main.box, key: "life")
                _ = LoopLayer.Host.loop(Self.frames("transform.translation.x", push.map { ($0.0, $0.1) }), on: strands[1].box, key: "life")
                _ = LoopLayer.Host.loop(Self.frames("transform.translation.x", push.map { ($0.0, -$0.1) }), on: strands[2].box, key: "life")
            case .bot:
                // 浮着上下飘，飘两下眨一次眼、天线跟着一抖
                for strand in strands {
                    _ = LoopLayer.Host.loop(Self.frames("transform.translation.y", [(0, 0), (0.9, -0.9), (1.8, 0), (2.7, -0.9), (3.6, 0)]), on: strand.box, key: "life")
                }
                for (eye, x) in zip(strands[4...5], [-3.0, 3.0]) {
                    eye.pivot(at: CGPoint(x: x, y: 2))
                    _ = LoopLayer.Host.loop(Self.frames("transform.scale.y", [(0, 1), (3, 1), (3.08, 0.12), (3.18, 1), (3.6, 1)]), on: eye.box, key: "blink")
                }
                strands[1].pivot(at: CGPoint(x: 0, y: -4))
                _ = LoopLayer.Host.loop(Self.frames("transform.rotation.z", Self.degrees([(0, 0), (2.95, 0), (3.1, -14), (3.3, 8), (3.5, 0), (3.6, 0)])), on: strands[1].box, key: "blink")
            case .flap:
                strands[1].pivot(at: CGPoint(x: 0, y: -6))
                InkBeat.shared.join(self, life)
            case .nod, .jitter, .rock:
                InkBeat.shared.join(self, life)
            case .still:
                break
            }
        }

        /// 不一直动的几种动的那一下（`InkBeat` 隔几秒敲一次，换进来时 `delay` 后也放一次）：只放动的这一秒，放完就摘，其余时间渲染服务不画。
        func beat(_ life: InkPose.Life, delay: Double = 0) {
            guard pose?.life == life else { return }
            let start = CACurrentMediaTime() + delay
            func play(_ move: CAKeyframeAnimation, on layer: CALayer, lag: Double = 0) {
                move.beginTime = start + lag
                move.fillMode = .backwards
                layer.add(move, forKey: "beat")
            }
            switch life {
            case .nod:
                // 歪一下头再回正，像在问
                play(Self.frames("transform.rotation.z", [(0, 0), (0.16, -0.2), (0.3, 0.12), (0.42, -0.04), (0.52, 0)]), on: ink)
            case .flap:
                // 信封盖往上掀开一下再合上：有一封给你的
                play(Self.frames("transform.scale.y", [(0, 1), (0.25, -0.55), (0.5, -0.55), (0.72, 1.08), (0.86, 1)]), on: strands[1].box)
            case .jitter:
                // 拔开的两半各往外一弹，像刚断开时那一下
                for (index, strand) in strands.enumerated() {
                    let away: CGFloat = [0, 2, 3, 4].contains(index) ? -1 : 1
                    play(Self.frames("transform.translation", [0, 1, -0.3, 0].enumerated().map { step, push in
                        ([0, 0.18, 0.36, 0.55][step], sizeValue(CGSize(width: away * push, height: -away * push)))
                    }), on: strand.box)
                }
            case .rock:
                // 月牙轻轻晃一下
                play(Self.frames("transform.rotation.z", [(0, 0), (0.35, -0.21), (0.7, 0.08), (1, 0)]), on: ink)
            default:
                break
            }
        }

        /// 颜色与亮度：在想的心跳底下那条轨是淡的，其余整根是实的。
        private func paint(animated: Bool) {
            guard let pose else { return }
            let alpha = color?.alpha ?? 1
            let track: CGFloat = pose.life == .pulse && loops ? 0.3 : 1
            for strand in strands {
                strand.tint(base: color?.copy(alpha: alpha * track), runner: color, animated: animated)
            }
        }

        /// 收起来的一根：一点，落在主线上离 `point` 最近的地方。
        private static func parked(near point: CGPoint, on spine: [CGPoint]) -> [CGPoint] {
            let spot = spine.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? .zero
            return Array(repeating: spot, count: InkStateGeometry.strandPoints)
        }

        private static func middle(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }

        /// 一段关键帧（时刻按秒、最后一个时刻就是时长），段与段缓入缓出；常驻的交给 `LoopLayer.Host.loop` 循环，敲一下的放完就摘。
        private static func frames(_ keyPath: String, _ keys: [(time: Double, value: Any)]) -> CAKeyframeAnimation {
            let move = CAKeyframeAnimation(keyPath: keyPath)
            let duration = keys.last!.time
            move.values = keys.map(\.value)
            move.keyTimes = keys.map { NSNumber(value: $0.time / duration) }
            move.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: keys.count - 1)
            move.duration = duration
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: Motion.Beat.frameRate, preferred: Motion.Beat.frameRate)
            return move
        }

        private static func degrees(_ keys: [(time: Double, angle: Double)]) -> [(time: Double, value: Any)] {
            keys.map { ($0.time, $0.angle * .pi / 180) }
        }

        private static func crossfade() -> CATransition {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.Fade.duration
            return fade
        }

        private static let grid = CGRect(x: -12, y: -12, width: 24, height: 24)
    }

    /// 一根线：`box` 管这根整体的动作（挤、跳、眨），`base` 是线本身，`runner` 是它上面走的那一截（只有主线用）。
    private final class Strand {
        let box = CALayer()
        let base = CAShapeLayer()
        let runner = CAShapeLayer()
        private(set) var points: [CGPoint] = Array(repeating: .zero, count: InkStateGeometry.strandPoints)
        private(set) var width: CGFloat = 0

        /// 这根线整体动作（转、压）绕的点（格）。动作只动 `transform` 的分量（转角、缩放、位移）：同一层上几段（飘、眨）各管一个分量才叠得起来，整块的 `transform` 关键帧会互相盖掉。
        func pivot(at point: CGPoint) {
            box.anchorPoint = CGPoint(x: (point.x + 12) / 24, y: (point.y + 12) / 24)
            box.position = point
        }

        func set(_ points: [CGPoint], width: CGFloat) {
            self.points = points
            self.width = width
            let path = Self.path(points)
            base.path = path
            runner.path = path
            base.lineWidth = width
            runner.lineWidth = width
        }

        /// 从此刻画着的样子弹过去（换到一半又换，接着此刻的样子走）。路径带一点回弹，线宽不弹：收成一点时宽度弹过零会翻出来。
        func morph(to points: [CGPoint], width: CGFloat, animated: Bool) {
            let shownPath = base.presentation()?.path ?? base.path
            let shownWidth = base.presentation()?.lineWidth ?? base.lineWidth
            set(points, width: width)
            guard animated else { return }
            for layer in [base, runner] {
                layer.add(Self.spring("path", from: shownPath, to: layer.path, bounce: Motion.Ink.bounce), forKey: "morph.path")
                layer.add(Self.spring("lineWidth", from: shownWidth, to: width, bounce: 0), forKey: "morph.width")
            }
        }

        func tint(base color: CGColor?, runner full: CGColor?, animated: Bool) {
            for (layer, value) in [(base, color), (runner, full)] {
                let shown = layer.presentation()?.strokeColor ?? layer.strokeColor
                layer.strokeColor = value
                if animated, shown != value {
                    let fade = CABasicAnimation(keyPath: "strokeColor")
                    fade.fromValue = shown
                    fade.toValue = value
                    fade.duration = Motion.Fade.duration
                    fade.timingFunction = Motion.Fade.timing
                    layer.add(fade, forKey: "morph.color")
                }
            }
        }

        private static func spring(_ keyPath: String, from: Any?, to: Any?, bounce: CGFloat) -> CASpringAnimation {
            let spring = CASpringAnimation(perceptualDuration: Motion.Ink.morph, bounce: bounce)
            spring.keyPath = keyPath
            spring.fromValue = from
            spring.toValue = to
            spring.duration = spring.settlingDuration
            return spring
        }

        private static func path(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points)
            return path
        }
    }
}

#if os(iOS)
extension StateInk: UIViewRepresentable {
    func makeUIView(context: Context) -> Host { Host(frame: .zero) }
    func updateUIView(_ host: Host, context: Context) {
        host.show(pose, color: color.resolve(in: context.environment).cgColor, loops: loops, morphs: morphs)
    }
}
#else
extension StateInk: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host(frame: .zero) }
    func updateNSView(_ host: Host, context: Context) {
        host.show(pose, color: color.resolve(in: context.environment).cgColor, loops: loops, morphs: morphs)
    }
}
#endif

private func sizeValue(_ size: CGSize) -> NSValue {
    #if os(macOS)
    NSValue(size: size)
    #else
    NSValue(cgSize: size)
    #endif
}
