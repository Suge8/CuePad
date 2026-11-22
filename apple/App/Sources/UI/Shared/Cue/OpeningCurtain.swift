import SwiftUI

/// 盖在窗口上的三层：墨色（开门时换成一格格散开的逐帧图）、光（点阵屏与字标，`OpeningLight`；开门时跟着墨色一格格碎掉）与小人。
final class OpeningCurtain {
    private let canvas = CALayer()
    private let veil = CALayer()
    private let light = CALayer()
    private let matrix = CALayer()
    private let mark = CALayer()
    private let figure = CALayer()
    private let world: CALayer?
    private let pose: (idle: CGImage, jump: CGImage)

    /// Cue 在墨色上等门开时一呼一吸地浮着（启动屏上它是静的，从原位起步，接缝看不出）。
    private static let breath = (rise: CGFloat(3), period: 1.4)

    init(root: CALayer, world: CALayer?, ink: CGColor, pose: (idle: CGImage, jump: CGImage), stage: OpeningDoor.Stage, mark still: CGImage, up: CGFloat, breathes: Bool) {
        self.world = world
        self.pose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = root.bounds
        veil.frame = root.bounds
        veil.backgroundColor = ink
        veil.magnificationFilter = .nearest
        light.frame = root.bounds
        matrix.frame = stage.grid.frame
        matrix.magnificationFilter = .nearest
        mark.frame = stage.mark
        mark.contents = still
        mark.magnificationFilter = .nearest
        figure.contents = pose.idle
        figure.contentsGravity = .resize
        figure.frame = stage.cue
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
        canvas.addSublayer(veil)
        light.addSublayer(matrix)
        light.addSublayer(mark)
        canvas.addSublayer(light)
        canvas.addSublayer(figure)
        canvas.zPosition = 10_001
        root.addSublayer(canvas)
        CATransaction.commit()
    }

    /// 点阵屏亮起来：从第 0 帧（一格不亮、字米白，与启动图接上）放到最后一帧停住。
    func glow(_ frames: OpeningLight.Frames) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dots = CALayer()
        dots.frame = matrix.bounds
        dots.contents = frames.dots
        matrix.mask = dots
        for (layer, values) in [(matrix, frames.matrix), (mark, frames.mark)] {
            let play = CAKeyframeAnimation(keyPath: "contents")
            play.values = values
            play.duration = OpeningLight.span
            play.calculationMode = .discrete
            layer.contents = values.last
            layer.add(play, forKey: "glow")
        }
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

    func open(_ door: OpeningDoor, veils: [CGImage]) async {
        let frames = door.frames, up = door.up
        await withCheckedContinuation { done in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { done.resume() }
            stopBreathing()
            veil.frame = matrix.frame
            veil.backgroundColor = nil
            veil.contents = veils.last
            let reveal = CAKeyframeAnimation(keyPath: "contents")
            reveal.values = veils
            reveal.duration = OpeningDoor.reveal
            reveal.calculationMode = .discrete
            veil.add(reveal, forKey: "reveal")
            let crumble = CALayer()
            crumble.frame = veil.frame
            crumble.contents = veils.last
            crumble.magnificationFilter = .nearest
            crumble.add(reveal, forKey: "reveal")
            light.mask = crumble
            figure.anchorPoint = CGPoint(x: 0.5, y: up < 0 ? 1 : 0)
            let foot = { (cue: CGRect) in CGPoint(x: cue.midX, y: up < 0 ? cue.maxY : cue.minY) }
            let last = frames.last!.cue
            figure.bounds = CGRect(origin: .zero, size: last.size)
            figure.position = foot(last)
            add(figure, "bounds.size", frames.map { Self.value($0.cue.size) })
            add(figure, "position", frames.map { Self.value(foot($0.cue)) })
            let hop = CAKeyframeAnimation(keyPath: "contents")
            hop.values = [pose.idle, pose.jump, pose.idle]
            hop.keyTimes = [0, OpeningDoor.crouch, OpeningDoor.crouch + OpeningDoor.airborne * OpeningDoor.flight].map { NSNumber(value: $0 / OpeningDoor.duration) }
            hop.calculationMode = .discrete
            hop.duration = OpeningDoor.duration
            figure.add(hop, forKey: "hop")
            if door.landing == nil { add(figure, "opacity", frames.indices.map { 1 - Double($0) / Double(frames.count - 1) }) }
            if let world {
                let center = canvas.convert(CGPoint(x: door.start.midX, y: door.start.midY), to: world)
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
                settle.beginTime = figure.convertTime(CACurrentMediaTime(), from: nil) + OpeningDoor.duration
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
}
