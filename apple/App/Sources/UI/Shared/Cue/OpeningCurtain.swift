import SwiftUI

/// 盖在窗口上的那几层：墨色（挖一个门洞）、门洞里的投影与内沿的光、环、小人。
final class OpeningCurtain {
    private let canvas = CALayer()
    private let ink = CAShapeLayer()
    private let depth = CAShapeLayer()
    private let depthMask = CAShapeLayer()
    private let lip = CAShapeLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let glow = CAGradientLayer()
    private let figure = CALayer()
    private let world: CALayer?

    private static let rimStops: [NSNumber] = [0, 0.2, 0.48, 0.72, 1]
    private static let shadowBlur: CGFloat = 14
    /// 环的高光从左上斜着照下来（CSS 的 165°）。
    private static let light = CGVector(dx: sin(165 * Double.pi / 180), dy: -cos(165 * Double.pi / 180))

    /// Cue 在墨色上等门开时一呼一吸地浮着（启动屏上它是静的，从原位起步，接缝看不出）。
    private static let breath = (rise: CGFloat(3), period: 1.4)

    init(root: CALayer, world: CALayer?, ink color: CGColor, ring: [CGColor], cue: CGImage, at start: CGRect, up: CGFloat, breathes: Bool) {
        self.world = world
        let bounds = root.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
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
        glow.type = .radial
        glow.colors = [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.isHidden = true
        figure.contents = cue
        figure.contentsGravity = .resizeAspect
        figure.frame = start
        if breathes {
            let breathe = CABasicAnimation(keyPath: "transform.translation.y")
            breathe.fromValue = 0
            breathe.toValue = up * Self.breath.rise
            breathe.duration = Self.breath.period / 2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            figure.add(breathe, forKey: "breathe")
        }
        canvas.addSublayer(glow)
        canvas.addSublayer(ink)
        canvas.addSublayer(depth)
        canvas.addSublayer(lip)
        canvas.addSublayer(rim)
        canvas.addSublayer(figure)
        canvas.zPosition = 10_001
        root.addSublayer(canvas)
        CATransaction.commit()
    }

    /// 呼吸停在半路的那一下，用 0.25 秒落回原位，不跳。
    private func stopBreathing() {
        guard figure.animation(forKey: "breathe") != nil else { return }
        let lift = figure.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        figure.removeAnimation(forKey: "breathe")
        let settle = CABasicAnimation(keyPath: "transform.translation.y")
        settle.fromValue = lift
        settle.toValue = 0
        settle.duration = 0.25
        settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
        figure.add(settle, forKey: "breathe")
    }

    func open(_ door: OpeningDoor) async {
        let frames = door.frames, bounds = canvas.bounds, up = door.up
        let bottom = CGPoint(x: 0.5, y: up < 0 ? 1 : 0)
        await withCheckedContinuation { done in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { done.resume() }
            stopBreathing()
            depth.isHidden = false
            rim.isHidden = false
            glow.isHidden = false
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
            add(glow, "bounds.size", frames.map { Self.value($0.hole.size) })
            add(glow, "position", frames.map { Self.value(CGPoint(x: $0.hole.midX, y: $0.hole.midY)) })
            add(glow, "opacity", frames.map { $0.light })
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
                settle.beginTime = figure.convertTime(CACurrentMediaTime(), from: nil) + OpeningDoor.duration * 0.94
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
        animation.duration = OpeningDoor.duration
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

    private static func ring(_ frame: OpeningDoor.Frame) -> CGPath {
        let path = CGMutablePath()
        let half = frame.tube / 2
        path.addEllipse(in: frame.ring.insetBy(dx: -half, dy: -half))
        path.addEllipse(in: frame.ring.insetBy(dx: half, dy: half), transform: CGAffineTransform(translationX: 2 * frame.ring.midX, y: 0).scaledBy(x: -1, y: 1))
        return path
    }

    /// 环的明暗按它自己的外框铺：渐变层铺满整窗，起止点随环换算成整窗的单位坐标。
    private static func lit(_ frame: OpeningDoor.Frame, in bounds: CGRect, up: CGFloat) -> (CGPoint, CGPoint) {
        let box = frame.ring.insetBy(dx: -frame.tube / 2, dy: -frame.tube / 2)
        let dx = light.dx, dy = light.dy * -up
        let half = (abs(box.width * dx) + abs(box.height * dy)) / 2
        let unit = { (x: CGFloat, y: CGFloat) in CGPoint(x: (x - bounds.minX) / bounds.width, y: (y - bounds.minY) / bounds.height) }
        return (unit(box.midX - dx * half, box.midY - dy * half), unit(box.midX + dx * half, box.midY + dy * half))
    }
}
