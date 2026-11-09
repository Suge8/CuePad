import QuartzCore
import SwiftUI

extension RelayFlight {
    enum Head { case dot, ring }

    struct Scene {
        let origin: CFTimeInterval
        private static let head: CGFloat = 8
        private static let ring: CGFloat = 11
        private static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.22, 1)
        /// 飞向头像的光（叫醒、发出）飞多久、飞到哪一成算到点：固定，到点时刻才能由起点推出（`CueWatch` 照它让小人醒，不等这里回报）。
        /// 到点就是路径终点，不随两端距离改变时长。
        private static let inboundFlight = 0.9
        private static let inboundArrive = 1.0
        static let inboundArrival = inboundFlight
        private static let flight = 0.78...1.08
        private static let pointsPerSecond = 1800.0
        private static let bend: CGFloat = 48
        private static let mostBend: CGFloat = 160
        private static let depart = 0.58
        private static let reception = 0.82
        private static let halo: CGFloat = 11
        private static let lit = 0.6
        private static let touch: CGFloat = 4
        /// 点亮时从几倍的点收到原大：再大就越出头像的框，读成头像外又一个东西。
        private static let litGrowth = 1.2
        private static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

        final class Pads {
            var layers: [CALayer] = []
        }

        let canvas: CALayer
        let pads: Pads
        let color: CGColor
        let up: CGFloat

        func receive(at landing: Landing, delay: Double, started: @escaping @MainActor () -> Void) {
            guard let host = landing.host else { return depart(at: landing.point, delay: delay, fills: true, started: started) }
            let pad = CALayer()
            pad.frame = host.bounds
            host.addSublayer(pad)
            pads.layers.append(pad)
            depart(at: CGPoint(x: host.bounds.midX, y: host.bounds.midY), in: pad, delay: delay, fills: true, started: started)
        }

        func depart(at point: CGPoint, in parent: CALayer? = nil, delay: Double, fills: Bool = false, started: (@MainActor () -> Void)? = nil) {
            animate(circle(at: point, radius: 6, line: 1.5, glows: true, in: parent), delay: delay, duration: Self.depart,
                    timing: Self.easeOut, started: started, [
                        Self.keyframes("transform.scale", [0.8, 2.6]), Self.keyframes("opacity", [1, 0]),
                    ])
            if fills {
                animate(circle(at: point, radius: 4, fill: 0.95, glows: true, in: parent), delay: delay, duration: Self.reception, [
                    Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.1, 0.42, 1]),
                    Self.keyframes("transform.scale", [0.9, 1.25, 1, 1], times: [0, 0.18, 0.42, 1]),
                ])
                animate(circle(at: point, radius: Self.halo, fill: 0.18, in: parent), delay: delay, duration: Self.reception, [Self.hold()])
            }
        }

        /// 否决过：按整段时长的固定几成（0.92）算到点——曲线先快后慢，光头早早就贴到落点、在那里淡着挪，按时长算的那一刻已晚约 0.2s，读成两件事。
        func fly(from start: CGPoint, to end: CGPoint, head: Head, delay: Double, launches: Bool = false, inbound: Bool = false) -> Double {
            let length = RelayFlight.distance(start, end)
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            var normal = CGPoint(x: -(end.y - start.y) / max(length, 1), y: (end.x - start.x) / max(length, 1))
            let outward = abs(normal.x) < 0.2 ? normal.y * up < 0 : normal.x * (canvas.bounds.midX - mid.x) < 0
            if outward { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let bend = min(max(length * 0.32, Self.bend), Self.mostBend)
            let control = CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend)
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            let duration = inbound ? Self.inboundFlight : min(Self.flight.lowerBound + Double(length) / Self.pointsPerSecond, Self.flight.upperBound)
            // 二次曲线的弧长：弦与控制折线的平均，差不到一成
            let arc = (length + RelayFlight.distance(start, control) + RelayFlight.distance(control, end)) / 2
            let arrive = inbound ? Self.inboundArrive : max(0.5, 1 - Double(Self.touch / max(arc, 1)))
            streak(path, head: head, delay: delay, duration: duration, timing: Self.glide, arrive: arrive, launches: launches)
            return inbound ? duration : duration * Self.time(Self.glide, reaching: arrive)
        }

        private static func time(_ timing: CAMediaTimingFunction, reaching progress: Double) -> Double {
            var one = [Float](repeating: 0, count: 2), two = [Float](repeating: 0, count: 2)
            timing.getControlPoint(at: 1, values: &one)
            timing.getControlPoint(at: 2, values: &two)
            func bezier(_ s: Double, _ a: Float, _ b: Float) -> Double {
                3 * (1 - s) * (1 - s) * s * Double(a) + 3 * (1 - s) * s * s * Double(b) + s * s * s
            }
            var low = 0.0, high = 1.0
            for _ in 0..<30 {
                let mid = (low + high) / 2
                if bezier(mid, one[1], two[1]) < progress { low = mid } else { high = mid }
            }
            return bezier(high, one[0], two[0])
        }

        func drift(from start: CGPoint, rise: CGFloat, head: Head, delay: Double, launches: Bool = false) {
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: CGPoint(x: start.x + 6, y: start.y + rise), control: CGPoint(x: start.x, y: start.y + rise * 0.6))
            streak(path, head: head, delay: delay, duration: 0.55, timing: Self.easeOut, fades: true, launches: launches)
        }

        /// 尾巴是同一条弧上的描边，终点跟着光走、起点晚一点出发、到终点时追上；三层叠出由亮到暗的尾巴（描边上不能铺沿着弧走的渐变）。
        /// `launches`：光是从钮上的机头变来的，第一帧就满大、不透明（不从半大淡入）。
        private func streak(
            _ path: CGPath, head: Head, delay: Double, duration: Double, timing: CAMediaTimingFunction, arrive: Double = 0.88, fades: Bool = false, launches: Bool = false
        ) {
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
                arrive == 1 ? Self.keyframes("transform.scale", [launches ? 1 : 0.5, 1.15, 1], times: [0, 0.2, 1])
                    : Self.keyframes("transform.scale", [launches ? 1 : 0.5, 1.15, 1, fades ? 0.6 : 0.4], times: [0, 0.2, NSNumber(value: fades ? 0.85 : arrive), 1]),
                arrive == 1 ? Self.keyframes("opacity", [launches ? 1 : 0, 1, 1], times: [0, 0.12, 1])
                    : Self.keyframes("opacity", [launches ? 1 : 0, 1, 1, 0], times: [0, 0.12, NSNumber(value: fades ? 0.5 : arrive), 1]),
            ])
        }

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

        func dot(of avatar: CGRect) -> CGPoint {
            let reach = CueFaceMarks.dotReach(min(avatar.width, avatar.height))
            return CGPoint(x: avatar.midX + reach, y: avatar.midY - up * reach)
        }

        func land(from start: CGPoint, on avatar: CGRect, delay: Double, launches: Bool = false) {
            let point = dot(of: avatar)
            let arrival = fly(from: start, to: point, head: .dot, delay: delay, launches: launches, inbound: true)
            light(dot: point, avatar: avatar, delay: delay + arrival)
        }

        /// 不带光晕、不在头像外画环、不外扩（头像外的环读成加载进度，否决过）：整个落在头像的框里。
        func light(dot point: CGPoint, avatar: CGRect, delay: Double) {
            let radius = CueFaceMarks.dotSide(min(avatar.width, avatar.height)) / 2
            animate(circle(at: point, radius: radius, fill: 1), delay: delay, duration: Self.lit, [
                Self.keyframes("opacity", [0, 1, 1, 0], times: [0, 0.12, 0.5, 1], timing: Self.easeOut),
                Self.keyframes("transform.scale", [Self.litGrowth, 1, 1, 1], times: [0, 0.3, 0.5, 1], timing: Self.easeOut),
            ])
        }

        func glow(dot point: CGPoint, delay: Double) {
            animate(circle(at: point, radius: 9, fill: 0.3), delay: delay, duration: 1, [Self.hold()])
        }

        private static func hold() -> CAAnimation {
            keyframes("opacity", [0, 1, 1, 0], times: [0, 0.2, 0.55, 1], timing: CAMediaTimingFunction(name: .easeInEaseOut))
        }

        private func circle(at point: CGPoint, radius: CGFloat, line: CGFloat? = nil, fill: CGFloat = 0, glows: Bool = false, in parent: CALayer? = nil) -> CAShapeLayer {
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
            (parent ?? canvas).addSublayer(shape)
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
            // 各层按自己的时间轴算起点（画布与锚在不同的父层里）
            group.beginTime = layer.convertTime(origin + delay, from: nil)
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
