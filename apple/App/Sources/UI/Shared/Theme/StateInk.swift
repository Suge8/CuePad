import QuartzCore
import SwiftUI

/// 会话状态标里的那根线：会话的每种状态都是这根线在做的事——在想时线上走着心跳，用工具时卷成圈转，压缩时挤成手风琴，
/// 等子代理时缩成一颗点抛出一颗小点，等你确认时弯成问号，该你了时末端是光标，歇着时断成省略号，被打断时折断，已结束时放平、尾巴落成句号。
/// 换状态是同一组线逐点变形过去（几何由 design/tools/ink/state_geometry.py 从符号的中线导出，每根同样点数），不换掉重画；
/// 不是线的状态（铃铛、出错的徽、纸飞机，`StateDot` 叠在上面）这组线收进中心。
/// 变形与常驻的动作都是 Core Animation、交给渲染服务（理由同 `LoopLayer`）；常驻动作只在 `loops` 时放，长时间挂着的几种每十几秒才动一下（`InkBeat`）。
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
            if old?.life != pose.life || looped != loops { live(pose.life) }
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

        /// 常驻的动作与各层的静止值（亮度、跑的那一截）。
        private func live(_ life: InkPose.Life) {
            for layer in [ink] + strands.flatMap({ [$0.box, $0.runner] }) {
                for key in layer.animationKeys() ?? [] where key == "life" || key == "beat" { layer.removeAnimation(forKey: key) }
            }
            let main = strands[0]
            main.runner.isHidden = !(life == .orbit || life == .pulse && loops)
            main.runner.strokeStart = 0
            main.runner.strokeEnd = life == .orbit ? Self.orbitArc : 0
            strands.forEach { $0.box.opacity = 1 }
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
            case .orbit:
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = Double.pi * 2
                spin.duration = 1.1
                _ = LoopLayer.Host.loop(spin, on: main.runner, key: "life")
            case .squeeze:
                let press = CABasicAnimation(keyPath: "transform.scale.x")
                press.fromValue = 1
                press.toValue = 0.5
                press.duration = 0.8
                press.autoreverses = true
                press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                _ = LoopLayer.Host.loop(press, on: main.box, key: "life")
            case .relay:
                let trip = CAKeyframeAnimation(keyPath: "transform.translation")
                let back = Self.relayBack
                trip.values = [CGSize.zero, .zero, CGSize(width: back, height: -back), CGSize(width: back, height: -back), .zero].map(sizeValue)
                trip.keyTimes = RelayMark.tripTimes.map(NSNumber.init(value:))
                trip.timingFunctions = [.init(controlPoints: 0.3, 0, 0.2, 1), .init(name: .linear), .init(controlPoints: 0.5, 0, 0.3, 1), .init(name: .linear)]
                trip.duration = RelayMark.period
                _ = LoopLayer.Host.loop(trip, on: strands[1].box, key: "life")
                let catchIt = CAKeyframeAnimation(keyPath: "transform.scale")
                catchIt.values = [1, 1, RelayMark.bulge, 1, 1]
                catchIt.keyTimes = RelayMark.catchTimes.map(NSNumber.init(value:))
                catchIt.duration = RelayMark.period
                _ = LoopLayer.Host.loop(catchIt, on: main.box, key: "life")
            case .nod, .blink, .hop, .breathe:
                InkBeat.shared.join(self, life)
                return
            case .still:
                break
            }
        }

        /// 长时间挂着的几种动的那一下（`InkBeat` 隔十几秒敲一次）：只放动的这一秒，放完就摘，其余时间渲染服务不画。
        func beat(_ life: InkPose.Life) {
            guard pose?.life == life else { return }
            switch life {
            case .nod:
                // 歪一下头再回正，像在问
                ink.add(Self.once("transform.rotation.z", [(0, 0), (0.16, -0.2), (0.3, 0.12), (0.42, -0.04), (0.52, 0)]), forKey: "beat")
            case .blink:
                // 光标眨两下，和文本框里的光标同一个节拍
                let blink = CAKeyframeAnimation(keyPath: "opacity")
                blink.calculationMode = .discrete
                blink.values = [0, 1, 0]
                blink.keyTimes = [0, 1.0 / 3, 2.0 / 3, 1].map(NSNumber.init(value:))
                blink.duration = 0.75
                strands[1].box.add(blink, forKey: "beat")
            case .hop:
                // 三颗点挨个跳一下，像对方在打字
                for (index, strand) in strands.enumerated() {
                    let hop = Self.once("transform.translation.y", [(0, 0), (0.18, -2.6), (0.42, 0.3), (0.56, 0)])
                    hop.beginTime = CACurrentMediaTime() + Double(index) * 0.12
                    hop.fillMode = .backwards
                    strand.box.add(hop, forKey: "beat")
                }
            case .breathe:
                strands[0].box.add(Self.once("transform.scale", [(0, 1), (0.5, 1.14), (1.3, 1)]), forKey: "beat")
            default:
                break
            }
        }

        /// 颜色与亮度：在跑的心跳、转圈底下那条轨是淡的，其余整根是实的。
        private func paint(animated: Bool) {
            guard let pose else { return }
            let alpha = color?.alpha ?? 1
            let track: CGFloat = switch pose.life {
            case .pulse where loops: 0.3
            case .orbit: 0.22
            default: 1
            }
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

        /// 放一次就摘的一下（时刻按秒）。
        private static func once(_ keyPath: String, _ keys: [(time: Double, value: Double)]) -> CAKeyframeAnimation {
            let move = CAKeyframeAnimation(keyPath: keyPath)
            let duration = keys.last!.time
            move.values = keys.map { NSNumber(value: $0.value) }
            move.keyTimes = keys.map { NSNumber(value: $0.time / duration) }
            move.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: keys.count - 1)
            move.duration = duration
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: Motion.Beat.frameRate, preferred: Motion.Beat.frameRate)
            return move
        }

        private static func crossfade() -> CATransition {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.Fade.duration
            return fade
        }

        private static let grid = CGRect(x: -12, y: -12, width: 24, height: 24)
        private static let orbitArc: CGFloat = 0.3
        /// 小点贴住大点时沿对角线往回挪多少格（同 `RelayMark` 的比例）。
        private static let relayBack: CGFloat = {
            let side = grid.width
            return (RelayMark.big + RelayMark.small) * side / 2 / 2.squareRoot() - RelayMark.reach * side
        }()
    }

    /// 一根线：`box` 管这根整体的动作（挤、跳、眨），`base` 是线本身，`runner` 是它上面走的那一截（只有主线用）。
    private final class Strand {
        let box = CALayer()
        let base = CAShapeLayer()
        let runner = CAShapeLayer()
        private(set) var points: [CGPoint] = Array(repeating: .zero, count: InkStateGeometry.strandPoints)
        private(set) var width: CGFloat = 0

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
