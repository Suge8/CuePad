import QuartzCore
import SwiftUI

extension RelayFlight {
    /// 飞的是什么：会话的状态标（实心点）或 Cue 的环（空心小环）。
    enum Head { case dot, ring }

    struct Scene {
        /// 飞着的那颗点（叫醒）与那个小环（交给）的直径。
        private static let head: CGFloat = 8
        private static let ring: CGFloat = 11
        /// 先加速、后长长地减速：落下时已经很慢。
        private static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.22, 1)
        private static let flight = 0.78...1.08
        private static let pointsPerSecond = 1800.0
        private static let bend: CGFloat = 48
        private static let mostBend: CGFloat = 160
        private static let ripple = 0.14
        private static let depart = 0.58
        private static let reception = 0.82
        private static let avatar = 0.78
        private static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        let canvas: CALayer
        let color: CGColor
        let now: CFTimeInterval
        let up: CGFloat

        /// 起飞时只漾一圈；接住时珠心先亮、停住，再随外圈淡下去。只叠画光，不改珠子本身的视图与布局。
        func depart(at point: CGPoint, delay: Double, fills: Bool = false, started: (@MainActor () -> Void)? = nil) {
            animate(circle(at: point, radius: 6, line: 1.5, glows: true), delay: delay, duration: Self.depart,
                    timing: Self.easeOut, started: started, [
                        Self.keyframes("transform.scale", [0.8, 2.6]), Self.keyframes("opacity", [1, 0]),
                    ])
            if fills {
                animate(circle(at: point, radius: 4, fill: 0.95, glows: true), delay: delay, duration: Self.reception, [
                    Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.1, 0.42, 1]),
                    Self.keyframes("transform.scale", [0.9, 1.25, 1, 1], times: [0, 0.18, 0.42, 1]),
                ])
                animate(circle(at: point, radius: 11, fill: 0.18), delay: delay, duration: Self.reception, [Self.hold()])
            }
        }

        /// 沿弧飞到 `end`，返回飞了多久。弧向窗口的竖中线那边鼓：从侧栏、屏边起飞时弧在屏内；几乎横着飞时往上鼓。
        func fly(from start: CGPoint, to end: CGPoint, head: Head, delay: Double, launches: Bool = false) -> Double {
            let length = RelayFlight.distance(start, end)
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            var normal = CGPoint(x: -(end.y - start.y) / max(length, 1), y: (end.x - start.x) / max(length, 1))
            let outward = abs(normal.x) < 0.2 ? normal.y * up < 0 : normal.x * (canvas.bounds.midX - mid.x) < 0
            if outward { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let bend = min(max(length * 0.32, Self.bend), Self.mostBend)
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend))
            let duration = min(Self.flight.lowerBound + Double(length) / Self.pointsPerSecond, Self.flight.upperBound)
            streak(path, head: head, delay: delay, duration: duration, timing: Self.glide, launches: launches)
            return duration
        }

        /// 另一头不在屏上：从 `start` 沿 `rise`（层坐标里的竖直位移）飘一小段淡去。
        func drift(from start: CGPoint, rise: CGFloat, head: Head, delay: Double, launches: Bool = false) {
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: CGPoint(x: start.x + 6, y: start.y + rise), control: CGPoint(x: start.x, y: start.y + rise * 0.6))
            streak(path, head: head, delay: delay, duration: 0.55, timing: Self.easeOut, fades: true, launches: launches)
        }

        /// 一道光加它的尾巴：尾巴是同一条弧上的描边，终点跟着光走、起点晚一点出发、到终点时追上——尾巴越飞越短，落下时被收进去。
        /// 三层叠出由亮到暗的尾巴：短而亮的芯、长而淡的身子、宽而很淡的光晕（描边上不能铺沿着弧走的渐变）。
        /// `launches`：光是从钮上的机头变来的，第一帧就满大、不透明（不从半大淡入）。
        private func streak(_ path: CGPath, head: Head, delay: Double, duration: Double, timing: CAMediaTimingFunction, fades: Bool = false, launches: Bool = false) {
            for (width, alpha, lag) in [(CGFloat(10), 0.12, 0.36), (4, 0.36, 0.25), (1.8, 0.95, 0.16)] {
                let trail = CAShapeLayer()
                // 描边只占轨迹的包围盒，不让三层拖尾都保持整窗大小的合成边界。
                let bounds = path.boundingBoxOfPath.insetBy(dx: -width, dy: -width)
                trail.frame = bounds
                var local = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                trail.path = path.copy(using: &local)
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
            let dot = self.head(head)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            animate(dot, delay: delay, duration: duration, timing: timing, [
                move,
                Self.keyframes("transform.scale", [launches ? 1 : 0.5, 1.15, 1, fades ? 0.6 : 0.4], times: [0, 0.2, 0.85, 1]),
                Self.keyframes("opacity", [launches ? 1 : 0, 1, 1, 0], times: [0, 0.12, fades ? 0.5 : 0.88, 1]),
            ])
        }

        /// 飞着的那颗：实心点或空心小环，外带一圈同色光晕（形状给定，不让渲染服务每帧从内容里另算）。
        private func head(_ head: Head) -> CALayer {
            let layer: CALayer
            switch head {
            case .dot:
                let side = Self.head
                layer = CALayer()
                layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                layer.cornerRadius = side / 2
                layer.backgroundColor = color
                layer.shadowPath = CGPath(ellipseIn: layer.bounds, transform: nil)
                layer.shadowRadius = side * 0.8
            case .ring:
                let side = Self.ring, line: CGFloat = 2
                let shape = CAShapeLayer()
                shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                let path = CGPath(ellipseIn: shape.bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
                shape.path = path
                shape.fillColor = nil
                shape.strokeColor = color
                shape.lineWidth = line
                shape.shadowPath = path.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 0)
                shape.shadowRadius = side * 0.5
                layer = shape
            }
            layer.shadowColor = color
            layer.shadowOpacity = 1
            layer.shadowOffset = .zero
            layer.opacity = 0
            canvas.addSublayer(layer)
            return layer
        }

        /// 叫醒落下：头像的环亮起（带一圈光晕），停一下再外扩到 1.6 倍淡去；稍后一圈细的涟漪扩得更远。不盖住它的脸。
        func land(on target: CGRect, delay: Double) {
            let (radius, line) = Self.ring(of: target)
            animate(circle(at: target.center, radius: radius, line: line, glows: true), delay: delay, duration: Self.avatar, [
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.12, 0.3, 1], timing: Self.easeOut),
                Self.keyframes("transform.scale", [1, 1, 1, 1.6], times: [0, 0.12, 0.3, 1], timing: Self.easeOut),
            ])
            animate(circle(at: target.center, radius: radius, line: max(1, line / 2)), delay: delay + Self.ripple, duration: Self.avatar, timing: Self.easeOut, [
                Self.keyframes("opacity", [0.7, 0]), Self.keyframes("transform.scale", [1, 2.1]),
            ])
        }

        /// 交给发出：头像的环亮一下（带光晕），外扩到 1.25 倍淡去；比叫醒落下的那一下短、扩得近——发出是一拍，接住才漾开。
        func send(from source: CGRect) {
            let (radius, line) = Self.ring(of: source)
            animate(circle(at: source.center, radius: radius, line: line, glows: true), delay: 0, duration: 0.6, [
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.15, 0.35, 1], timing: Self.easeOut),
                Self.keyframes("transform.scale", [1, 1, 1, 1.25], times: [0, 0.15, 0.35, 1], timing: Self.easeOut),
            ])
        }

        /// 减弱动态效果：头像的环原地淡入高亮再淡出。
        func glow(ring target: CGRect) {
            let (radius, line) = Self.ring(of: target)
            animate(circle(at: target.center, radius: radius, line: line, glows: true), delay: 0, duration: 1, [Self.hold()])
        }

        /// 减弱动态效果：会话那头的状态标垫一层淡光，与头像同时亮、同时暗。
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
            } else {
                shape.fillColor = color.copy(alpha: color.alpha * fill)
            }
            if glows, let path = shape.path {
                shape.shadowPath = line.map { path.copy(strokingWithWidth: $0, lineCap: .round, lineJoin: .round, miterLimit: 0) } ?? path
                shape.shadowColor = color
                shape.shadowOpacity = 0.9
                shape.shadowRadius = max(4, (line ?? radius) * 1.6)
                shape.shadowOffset = .zero
            }
            shape.opacity = 0
            canvas.addSublayer(shape)
            return shape
        }

        /// 一组动画在 `delay` 之后开始；之前之后都是层的模型值（透明）。不往前填（`fillMode` 留默认）：往前填时晚开始的那几层
        /// 在开始前就停在第一帧上——落下时才该外扩的环、稍晚的涟漪会在光还没到时就亮着。
        private func animate(
            _ layer: CALayer, delay: Double, duration: Double, timing: CAMediaTimingFunction? = nil, started: (@MainActor () -> Void)? = nil,
            _ animations: [CAAnimation]
        ) {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.beginTime = now + delay
            group.timingFunction = timing
            group.delegate = started.map(Started.init)
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

/// 动画真的开始（过了 `beginTime`、渲染服务开播）时回调一次：落点那圈环的开始就是光落下的那一刻。
private final class Started: NSObject, CAAnimationDelegate {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    nonisolated func animationDidStart(_ animation: CAAnimation) { MainActor.assumeIsolated { run() } }
}
