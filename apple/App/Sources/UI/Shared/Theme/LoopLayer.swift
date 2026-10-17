import QuartzCore
import SwiftUI

/// 常驻循环动效的唯一宿主：Agent 在跑的心电线（`heartbeat`）、话在路上的三块实心 V（`climb`）、等你确认的外扩波纹（`ripple`）、
/// 等待的转圈（`orbit`，经 `Spinner`）、换模型与思考强度在路上时的呼吸（`pulse`）、进行中文字与最高思考强度上扫过的光（`sheen`）、
/// Agent 在做时任务浮窗里吉祥物的轻轻上下浮动、Cue 在做事时头像里的它上下跳（`float`）。
/// 用 Core Animation 而不是 SwiftUI 的 repeatForever 或符号动效：后两者每帧都在 App 进程里重算，
/// 列表里有几个在工作的会话时，静止不动也要占约 9% CPU；CA 的动画交给渲染服务，App 进程不参与，离屏不画。
/// 减弱动态效果时由调用方不放它（或换成静止的样子）。
struct LoopLayer {
    enum Kind: Equatable {
        /// 一圈淡轨道上一段弧匀速转，1.1s 一圈；线宽默认是直径的 14%，给了就用给的（Cue 头像外的状态环，粗细随头像尺寸另定）。
        case orbit(lineWidth: CGFloat? = nil)
        /// 心电线：淡色的一段心电波形上，一截实色沿波形从左走到右，1.4s 一趟；线宽是边长的 9%，淡波形是三成的颜色。
        case heartbeat
        /// 三块实心的 V 从下往上依次亮起再暗下去，1.2s 一轮，相邻两层差 0.18s；形状只在 `ClimbBlocks`（与符号 cue.climb 同出 design/tools/cue-symbols.py）。
        /// 不播时（截图、Mac 不在前台时只画的那一帧）是最上面一块亮着、往下渐暗，看得出方向。
        case climb
        /// 一圈细线从内切圆的大小往外扩到 1.6 倍、淡到看不见，2.4s 一次；线宽是边长的 7%。
        case ripple
        /// 一道横向的光带（宽是整体的一半）从左外扫到右外，1.8s 一趟。
        case sheen
        /// 铺满的一层颜色从无到有再回去，一明一暗 1.4s（盖在内容上，内容看起来在呼吸）。
        case pulse
        /// 一张图（等比铺满）上下浮动 `lift`，一上一下 1.8s。
        case float(CGImage, lift: CGFloat = 8)
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
            case .heartbeat, .climb, .ripple:
                loop.frame = bounds
                let side = min(bounds.width, bounds.height)
                let paths = Self.strokes(kind, side: side)
                for (index, shape) in (loop.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
                    shape.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
                    shape.path = paths[index]
                    if kind == .climb {
                        // 实心块：填色，不描边
                        shape.fillColor = color
                        shape.strokeColor = nil
                        continue
                    }
                    shape.lineWidth = side * (kind == .ripple ? 0.07 : 0.09)
                    // 心电线的第一层是垫底的淡波形
                    shape.strokeColor = kind == .heartbeat && index == 0 ? color?.copy(alpha: (color?.alpha ?? 1) * 0.3) : color
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
                // 一截实色沿波形走：终点先走、起点晚一点跟上，两者之间就是走着的那一截
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
            case .climb:
                let layer = CALayer()
                // 从下往上：每层比下面一层晚亮一点（用相位而不是 beginTime：层进窗口前就开始算时间）
                for delay in [0, 0.18, 0.36] {
                    let chevron = stroke()
                    let glow = CAKeyframeAnimation(keyPath: "opacity")
                    glow.values = [0.2, 1, 0.2, 0.2]
                    glow.keyTimes = [0, 0.25, 0.6, 1]
                    glow.duration = 1.2
                    // 整体往后错 0.66s：起播那一帧正好是最上面一块亮着、往下渐暗；三层之间的节奏不变
                    glow.timeOffset = glow.duration - delay + 0.66
                    // 没有动画时（模型值）也是最上面一块亮着
                    chevron.opacity = delay == 0.36 ? 1 : 0.2
                    layer.addSublayer(loop(glow, on: chevron))
                }
                return layer
            case .ripple:
                let layer = CALayer()
                let ring = stroke()
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1
                grow.toValue = 1.6
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.5
                fade.toValue = 0
                let wave = CAAnimationGroup()
                wave.animations = [grow, fade]
                wave.duration = 2.4
                wave.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.3, 1)
                layer.addSublayer(loop(wave, on: ring))
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
            case .float(let image, let lift):
                let layer = CALayer()
                layer.contents = image
                layer.contentsGravity = .resizeAspect
                let bob = CABasicAnimation(keyPath: "transform.translation.y")
                bob.fromValue = 0
                bob.toValue = lift
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

        /// 只描边、圆头圆角的一层（心电线、箭头、波纹）。
        private static func stroke() -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            return shape
        }

        /// 形状类动效每一层的路径（心电线、波纹是描边，三块 V 是闭合的实心块），画在边长 `side` 的正方形里（设计稿是 22 × 22、y 朝下的格子）。
        /// macOS 的层 y 朝上，统一翻过来，否则箭头朝下、心电线上下颠倒。
        private static func strokes(_ kind: Kind, side: CGFloat) -> [CGPath] {
            let unit = side / 22
            func path(_ points: [CGPoint], closed: Bool = false) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points.map { point in
                    #if os(macOS)
                    CGPoint(x: point.x * unit, y: (22 - point.y) * unit)
                    #else
                    CGPoint(x: point.x * unit, y: point.y * unit)
                    #endif
                })
                if closed { path.closeSubpath() }
                return path
            }
            switch kind {
            case .heartbeat:
                let wave = path([CGPoint(x: 1, y: 11), CGPoint(x: 5.5, y: 11), CGPoint(x: 7.5, y: 4.5), CGPoint(x: 11, y: 17.5),
                                 CGPoint(x: 13.5, y: 8), CGPoint(x: 15, y: 11), CGPoint(x: 21, y: 11)])
                return [wave, wave]
            case .climb:
                return ClimbBlocks.blocks.map { path($0, closed: true) }
            case .ripple:
                let inset = side * 0.07 / 2
                return [CGPath(ellipseIn: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2), transform: nil)]
            default:
                return []
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
                Circle().stroke(palette.track, lineWidth: width)
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
