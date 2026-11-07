#if os(macOS)
import SwiftUI

/// 分层纸片角色：身体保持同一张纹理，视线与手腕从各自 presentation layer 的当前值接续。
/// 循环只复用 LoopLayer 的眨眼时钟；换姿态是渲染端的一次性插值，不逐帧重算 SwiftUI。
struct CueVoicePuppet: NSViewRepresentable {
    let image: CGImage
    let pose: Pose
    let animate: Bool
    let blinking: Bool

    struct Hand: Equatable {
        let x: CGFloat
        let y: CGFloat
        let angle: CGFloat
    }

    struct Pose: Equatable {
        let left: Hand
        let right: Hand
        let gaze: CGPoint
        let worried: Bool

        init(activity: CueVoicePresentation.Activity, muted: Bool, emphasis: Bool) {
            worried = activity == .failed
            switch activity {
            case .listening where !muted:
                left = Hand(x: 53, y: 125, angle: 82)
                right = Hand(x: 193, y: 146, angle: 66)
                gaze = CGPoint(x: -3, y: 0)
            case .processing:
                left = Hand(x: 80, y: 153, angle: 38)
                right = Hand(x: 193, y: 146, angle: 66)
                gaze = CGPoint(x: 0, y: -5)
            case .speaking:
                left = Hand(x: 59, y: emphasis ? 130 : 139, angle: emphasis ? 20 : 0)
                right = Hand(x: 195, y: emphasis ? 140 : 148, angle: emphasis ? -18 : 8)
                gaze = CGPoint(x: 1, y: 0)
            case .failed:
                left = Hand(x: 76, y: 80, angle: 0)
                right = Hand(x: 193, y: 146, angle: 66)
                gaze = CGPoint(x: 0, y: 2)
            default:
                left = Hand(x: 59, y: 140, angle: -65)
                right = Hand(x: 193, y: 146, angle: 66)
                gaze = .zero
            }
        }
    }

    func makeNSView(context: Context) -> Host { Host(image: image) }
    func updateNSView(_ host: Host, context: Context) { host.show(pose, animate: animate, blinking: blinking) }

    final class Host: NSView {
        private enum Part: Int, CaseIterable { case body, leftEye, rightEye, leftHand, rightHand, brows }
        private let parts = Part.allCases.map { _ in CALayer() }
        private var pose: Pose?
        private var blinking = false
        private var drawnSize = CGSize.zero
        private static let side: CGFloat = 240
        private static let stride: CGFloat = 242
        private static let leftEye = CGPoint(x: 84, y: 106)
        private static let rightEye = CGPoint(x: 130, y: 98)
        private static let blinkInterval = 5.8

        init(image: CGImage) {
            super.init(frame: .zero)
            wantsLayer = true
            for part in Part.allCases {
                let sprite = parts[part.rawValue]
                sprite.contents = image
                sprite.contentsGravity = .resize
                sprite.contentsRect = CGRect(x: CGFloat(part.rawValue) * Self.stride / CGFloat(image.width), y: 0,
                                             width: Self.side / CGFloat(image.width), height: 1)
                layer?.addSublayer(sprite)
            }
            parts[Part.leftEye.rawValue].anchorPoint = CGPoint(x: Self.leftEye.x / Self.side, y: Self.leftEye.y / Self.side)
            parts[Part.rightEye.rawValue].anchorPoint = CGPoint(x: Self.rightEye.x / Self.side, y: Self.rightEye.y / Self.side)
        }

        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            guard bounds.size != drawnSize else { return }
            drawnSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sprite in parts { sprite.bounds = CGRect(origin: .zero, size: bounds.size) }
            for part in [Part.body, .brows] { parts[part.rawValue].position = CGPoint(x: bounds.midX, y: bounds.midY) }
            CATransaction.commit()
            if let pose { apply(pose, animated: false) }
        }

        func show(_ pose: Pose, animate: Bool, blinking: Bool) {
            if self.pose != pose || !animate {
                apply(pose, animated: animate && self.pose != nil)
                self.pose = pose
            }
            guard self.blinking != blinking else { return }
            self.blinking = blinking
            for part in [Part.leftEye, .rightEye] {
                let eye = parts[part.rawValue]
                eye.removeAnimation(forKey: "blink")
                if blinking { _ = LoopLayer.Host.loop(Self.blink(), on: eye, key: "blink") }
            }
        }

        private func apply(_ pose: Pose, animated: Bool) {
            let unit = bounds.width / Self.side
            for (part, hand) in [(Part.leftHand, pose.left), (.rightHand, pose.right)] {
                set(part, "position", NSValue(point: CGPoint(x: hand.x * unit, y: hand.y * unit)), animated: animated)
                set(part, "transform.rotation.z", hand.angle * .pi / 180, animated: animated)
            }
            for (part, center) in [(Part.leftEye, Self.leftEye), (.rightEye, Self.rightEye)] {
                set(part, "position", NSValue(point: CGPoint(x: (center.x + pose.gaze.x) * unit, y: (center.y + pose.gaze.y) * unit)), animated: animated)
            }
            set(.brows, "opacity", pose.worried ? 1.0 : 0.0, animated: animated)
        }

        private func set(_ part: Part, _ key: String, _ value: Any, animated: Bool) {
            let sprite = parts[part.rawValue]
            let previous = sprite.presentation()?.value(forKeyPath: key) ?? sprite.value(forKeyPath: key)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.setValue(value, forKeyPath: key)
            sprite.removeAnimation(forKey: key)
            if animated, let previous, !(previous as? NSObject ?? NSNull()).isEqual(value) {
                let change = CABasicAnimation(keyPath: key)
                change.fromValue = previous
                change.toValue = value
                change.duration = Motion.Glide.duration
                change.timingFunction = Motion.Glide.timing
                sprite.add(change, forKey: key)
            }
            CATransaction.commit()
        }

        private static func blink() -> CAKeyframeAnimation {
            let close = Motion.Beat.halfBlink, hold = Motion.Beat.blink
            let start = blinkInterval - close * 2 - hold
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 1, 0.12, 0.12, 1]
            blink.keyTimes = [0, start / blinkInterval, (start + close) / blinkInterval, (start + close + hold) / blinkInterval, 1].map(NSNumber.init(value:))
            blink.duration = blinkInterval
            return blink
        }
    }
}
#endif
