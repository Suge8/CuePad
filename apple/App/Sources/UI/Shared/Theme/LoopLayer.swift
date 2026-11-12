import QuartzCore
import SwiftUI

/// 用 Core Animation 而不是 SwiftUI 的 repeatForever 或符号动效：后两者每帧都在 App 进程里重算，
/// 列表里有几个在工作的会话时，静止不动也要占约 9% CPU；CA 的动画交给渲染服务，App 进程不参与，离屏不画。
/// 放不放只看 `LoopsPlay`，不放时调用方换静止的样子。
struct LoopLayer {
    enum Kind: Equatable {
        case orbit
        case voice(VoiceRibbon)
        case heartbeat
        /// "发出"一族只有纸飞机（与发送钮、"已送达"同一架，`Icon.send`）：发送中、已送达都是它，胖箭头只表示方向。不播时（截图、Mac 不在前台时只画的那一帧）停在正中。
        case flight
        case sheen
        case pulse
        case aura(radius: CGFloat)
        case relay
        case sprite(CueSprite, CueAtlas.Sheet)
    }

    let kind: Kind
    let color: Color
    /// 帧序列的 `intro` 放不放：只在换成这一拍的那一下（`JellyPhase.entering`）放，层重建（切页回来、省电关了又开）不放。
    var intro = false

    final class Host: LoopHostBase {
        private(set) var kind: Kind?
        private var color: CGColor?

        #if os(iOS)
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutLoop()
        }

        private var root: CALayer { layer }
        private var displayScale: CGFloat { traitCollection.displayScale }
        #else
        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        /// 层的坐标与 iOS 一样 y 朝下：路径、位移、转角两端同一套，不再各处分平台翻（`contents` 的位图不随之颠倒）。
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            layoutLoop()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var root: CALayer { layer! }
        private var displayScale: CGFloat { window?.backingScaleFactor ?? 2 }
        #endif

        required init?(coder: NSCoder) { fatalError() }

        func show(_ kind: Kind, color: CGColor?, intro: Bool) {
            // 调用方每帧重算时（软糖放着，`JellyFrame`）值没变不碰图层
            guard kind != self.kind || color != self.color else { return }
            if case .voice = kind, case .voice = self.kind {
                self.kind = kind
            } else if kind != self.kind {
                self.kind = kind
                root.sublayers?.forEach { $0.removeFromSuperlayer() }
                root.addSublayer(Self.make(kind, intro: intro))
            }
            self.color = color
            layoutLoop()
        }

        private func layoutLoop() {
            guard let loop = root.sublayers?.first, let kind else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let bounds = root.bounds
            switch kind {
            case .voice(let ribbon):
                (loop as? VoiceRibbonLayer)?.show(ribbon, in: bounds, color: color)
            case .orbit:
                loop.frame = bounds
                let width = min(bounds.width, bounds.height) * 0.14
                let ring = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size).insetBy(dx: width / 2, dy: width / 2), transform: nil)
                for (index, shape) in (loop.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
                    shape.frame = loop.bounds
                    shape.path = ring
                    shape.lineWidth = width
                    shape.strokeColor = index == 0 ? color?.copy(alpha: (color?.alpha ?? 1) * 0.22) : color
                }
            case .flight:
                loop.frame = bounds
                guard let plane = loop.sublayers?.first, let mask = plane.mask else { break }
                let side = min(bounds.width, bounds.height)
                plane.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
                plane.backgroundColor = color
                // 剪影与飞的距离只随边长（剪影还随屏幕倍数）变：每次更新都重挂的话飞到一半的那一趟从头再飞
                guard mask.frame.size != plane.bounds.size || mask.contentsScale != displayScale else { break }
                mask.frame = plane.bounds
                mask.contentsScale = displayScale
                mask.contents = Self.plane(side: side, scale: displayScale)
                if let fly = plane.animation(forKey: "loop")?.copy() as? CAAnimationGroup {
                    fly.animations = Self.flightPath(side: side)
                    plane.add(fly, forKey: "loop")
                }
            case .heartbeat:
                loop.frame = bounds
                let side = min(bounds.width, bounds.height)
                let wave = InkStateGeometry.heartbeat(in: CGRect(x: 0, y: 0, width: side, height: side))
                for (index, shape) in (loop.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
                    shape.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
                    shape.path = wave
                    shape.lineWidth = side * InkStateGeometry.heartbeatStrokeRatio
                    shape.strokeColor = index == 0 ? color?.copy(alpha: (color?.alpha ?? 1) * 0.3) : color
                }
            case .pulse:
                loop.frame = bounds
                loop.backgroundColor = color
            case .aura(let radius):
                Self.layoutAura(loop, in: bounds, radius: radius, color: color)
            case .relay:
                Self.layoutRelay(loop, in: bounds, color: color)
            case .sprite:
                Self.layoutSprite(loop, in: bounds)
            case .sheen:
                let band = bounds.width * 0.5
                loop.bounds = CGRect(x: 0, y: 0, width: band, height: bounds.height)
                loop.position = CGPoint(x: -band / 2, y: bounds.midY)
                (loop as? CAGradientLayer)?.colors = [color?.copy(alpha: 0), color, color?.copy(alpha: 0)].compactMap { $0 }
                if let sweep = loop.animation(forKey: "loop")?.copy() as? CABasicAnimation {
                    sweep.toValue = bounds.width + band
                    loop.add(sweep, forKey: "loop")
                }
            }
            CATransaction.commit()
        }

        private static func make(_ kind: Kind, intro: Bool) -> CALayer {
            switch kind {
            case .voice:
                return VoiceRibbonLayer()
            case .orbit:
                let layer = CALayer()
                let track = CAShapeLayer(), arc = CAShapeLayer()
                for shape in [track, arc] {
                    shape.fillColor = nil
                    shape.lineCap = .round
                    layer.addSublayer(shape)
                }
                arc.strokeEnd = 0.3
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = Double.pi * 2
                spin.duration = 1.1
                return loop(spin, on: layer)
            case .heartbeat:
                let layer = CALayer()
                let base = stroke(), run = stroke()
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
                for sublayer in [base, run] { layer.addSublayer(sublayer) }
                _ = loop(walk, on: run)
                return layer
            case .flight:
                let layer = CALayer()
                layer.masksToBounds = true
                let plane = CALayer()
                plane.mask = CALayer()
                let fly = CAAnimationGroup()
                fly.duration = Flight.period
                layer.addSublayer(loop(fly, on: plane))
                return layer
            case .pulse:
                let layer = CALayer()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 0.55
                fade.duration = 0.7
                fade.autoreverses = true
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return loop(fade, on: layer)
            case .relay:
                return makeRelay()
            case .sprite(let sprite, let sheet):
                return makeSprite(sprite, on: sheet, intro: intro)
            case .aura:
                return makeAura()
            case .sheen:
                let layer = CAGradientLayer()
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = 0
                sweep.toValue = 0
                sweep.duration = 1.8
                sweep.isAdditive = true
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return loop(sweep, on: layer)
            }
        }

        private static func stroke() -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            return shape
        }

        /// 挂一条常驻循环：退到后台再回来时不被系统摘掉；最高 `Motion.Beat.frameRate` 帧；起点按全局时钟对齐到周期的整数倍，
        /// 同屏同一种循环（两只头像的眨眼、一列心电线）同相——各从自己建出来那一刻起跳的话，两只头像各眨各的，读成两个角色。
        static func loop(_ animation: CAAnimation, on layer: CALayer, key: String = "loop") -> CALayer {
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: Motion.Beat.frameRate, preferred: Motion.Beat.frameRate)
            let now = CACurrentMediaTime()
            let period = animation.duration * (animation.autoreverses ? 2 : 1)
            animation.beginTime = layer.convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: period)
            layer.add(animation, forKey: key)
            return layer
        }
    }
}

#if os(iOS)
typealias LoopHostBase = UIView
extension LoopLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> Host { Host(frame: .zero) }
    func updateUIView(_ host: Host, context: Context) { host.show(kind, color: color.resolve(in: context.environment).cgColor, intro: intro) }
}
#else
typealias LoopHostBase = NSView
extension LoopLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host(frame: .zero) }
    func updateNSView(_ host: Host, context: Context) { host.show(kind, color: color.resolve(in: context.environment).cgColor, intro: intro) }
}
#endif

/// 常驻循环动效（`LoopLayer`）此刻放不放，全 App 只这一条：减弱动态效果、省电模式、页不在前台（`pageActive`）时不放。
/// 不看 `scenePhase`：Mac 的窗口由 AppKit 托管、没有 SwiftUI 场景，它一直不是 active，看它的动效在 Mac 上永远不动；
/// 也不看窗口有没有焦点：人在别的 App 里瞟一眼，在做事的就该在动。出屏、iOS 进后台的层渲染服务本来不画。
@propertyWrapper struct LoopsPlay: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var pageActive

    var wrappedValue: Bool { pageActive && !reduceMotion && !LowPowerMode.shared.isOn }
}

@Observable private final class LowPowerMode {
    static let shared = LowPowerMode()
    private(set) var isOn: Bool

    private init() {
        let changes = NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange)
        isOn = ProcessInfo.processInfo.isLowPowerModeEnabled  // 订上之后再读：其间的切换不漏
        Task {
            for await _ in changes {
                isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}
