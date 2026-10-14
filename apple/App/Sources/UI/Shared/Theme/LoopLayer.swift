import QuartzCore
import SwiftUI

/// 常驻循环动效的唯一宿主：工作中的转圈与等待的转圈（`orbit`，后者经 `Spinner`）、换模型与思考强度在路上时的呼吸（`pulse`）、话在路上的呼吸（`breath`）、进行中文字与最高思考强度上扫过的光（`sheen`）、
/// Agent 在做时任务浮窗里吉祥物的轻轻上下浮动（`float`）。
/// 用 Core Animation 而不是 SwiftUI 的 repeatForever 或符号动效：后两者每帧都在 App 进程里重算，
/// 列表里有几个在工作的会话时，静止不动也要占约 9% CPU；CA 的动画交给渲染服务，App 进程不参与，离屏不画。
/// 减弱动态效果时由调用方不放它（或换成静止的样子）。
struct LoopLayer {
    enum Kind: Equatable {
        /// 铺满的圆从 0.7 倍呼到 1.6 倍、淡到看不见，再回来，一呼一吸 2.4s。
        case breath
        /// 一圈淡轨道上一段弧匀速转，1.1s 一圈；线宽默认是直径的 14%，给了就用给的（Cue 头像外的状态环，粗细随头像尺寸另定）。
        case orbit(lineWidth: CGFloat? = nil)
        /// 一道横向的光带（宽是整体的一半）从左外扫到右外，1.8s 一趟。
        case sheen
        /// 铺满的一层颜色从无到有再回去，一明一暗 1.4s（盖在内容上，内容看起来在呼吸）。
        case pulse
        /// 一张图（等比铺满）上下浮动 8pt，一上一下 1.8s。
        case float(CGImage)
    }

    let kind: Kind
    let color: Color

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
        #else
        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        override func layout() {
            super.layout()
            layoutLoop()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var root: CALayer { layer! }
        #endif

        required init?(coder: NSCoder) { fatalError() }

        func show(_ kind: Kind, color: CGColor?) {
            if kind != self.kind {
                self.kind = kind
                root.sublayers?.forEach { $0.removeFromSuperlayer() }
                root.addSublayer(Self.make(kind))
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
            case .breath:
                loop.frame = bounds
                (loop as? CAShapeLayer)?.path = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size), transform: nil)
                (loop as? CAShapeLayer)?.fillColor = color
            case .orbit(let line):
                loop.frame = bounds
                let width = line ?? min(bounds.width, bounds.height) * 0.14
                let ring = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size).insetBy(dx: width / 2, dy: width / 2), transform: nil)
                for (index, shape) in (loop.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
                    shape.frame = loop.bounds
                    shape.path = ring
                    shape.lineWidth = width
                    shape.strokeColor = index == 0 ? color?.copy(alpha: (color?.alpha ?? 1) * 0.22) : color
                }
            case .pulse:
                loop.frame = bounds
                loop.backgroundColor = color
            case .float:
                loop.frame = bounds
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

        private static func make(_ kind: Kind) -> CALayer {
            switch kind {
            case .breath:
                let layer = CAShapeLayer()
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.7
                grow.toValue = 1.6
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                let breath = CAAnimationGroup()
                breath.animations = [grow, fade]
                breath.duration = 1.2
                breath.autoreverses = true
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return loop(breath, on: layer)
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
            case .pulse:
                let layer = CALayer()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 0.55
                fade.duration = 0.7
                fade.autoreverses = true
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return loop(fade, on: layer)
            case .float(let image):
                let layer = CALayer()
                layer.contents = image
                layer.contentsGravity = .resizeAspect
                let bob = CABasicAnimation(keyPath: "transform.translation.y")
                bob.fromValue = 0
                bob.toValue = 8
                bob.duration = 0.9
                bob.autoreverses = true
                bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return loop(bob, on: layer)
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

        private static func loop(_ animation: CAAnimation, on layer: CALayer) -> CALayer {
            animation.repeatCount = .infinity
            // 退到后台再回来时不被系统摘掉
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "loop")
            return layer
        }
    }
}

/// 全 App 唯一的等待转圈（发送中、送达中、读下一页、正在开…）：与 Agent 状态标同一段弧（`orbit`），交给渲染服务转，App 进程不参与；
/// 不用系统 `ProgressView`，全 App 的转圈是同一个样子、同一个颜色。减弱动态效果时是一段静止的弧。读屏读作"请稍候"，旁边的文字说在等什么。
struct Spinner: View {
    enum Size {
        case mini, small, regular
        var side: CGFloat {
            switch self {
            case .mini: 11
            case .small: 15
            case .regular: 20
            }
        }
    }

    var size = Size.small
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ size: Size = .small) { self.size = size }

    var body: some View {
        Group {
            if reduceMotion {
                let width = size.side * 0.14
                Circle().stroke(palette.ink2.opacity(0.22), lineWidth: width)
                    .overlay { Circle().trim(from: 0, to: 0.3).stroke(palette.ink2, style: StrokeStyle(lineWidth: width, lineCap: .round)) }
                    .padding(width / 2)
            } else {
                LoopLayer(kind: .orbit(), color: palette.ink2)
            }
        }
        .frame(width: size.side, height: size.side)
        .accessibilityElement()
        .accessibilityLabel("请稍候")
    }
}

#if os(iOS)
typealias LoopHostBase = UIView
extension LoopLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> Host { Host(frame: .zero) }
    func updateUIView(_ host: Host, context: Context) { host.show(kind, color: color.resolve(in: context.environment).cgColor) }
}
#else
typealias LoopHostBase = NSView
extension LoopLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host(frame: .zero) }
    func updateNSView(_ host: Host, context: Context) { host.show(kind, color: color.resolve(in: context.environment).cgColor) }
}
#endif
