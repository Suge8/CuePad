import QuartzCore
import SwiftUI

/// 常驻循环动效的唯一宿主：Agent 在跑的心电线（`heartbeat`）、话在路上的纸飞机（`flight`）、等你确认的外扩波纹（`ripple`）、
/// 等待的转圈（`orbit`，经 `Spinner`）、Cue 在做事时头像外绕着的彗星（`comet`）、换模型与思考强度在路上时的呼吸（`pulse`）、进行中文字与最高思考强度上扫过的光（`sheen`）、
/// Agent 在做时任务气泡里吉祥物的轻轻上下浮动（`float`）、看板推进中卡下沿那条线（`wave`，`BoardWave`）。
/// 用 Core Animation 而不是 SwiftUI 的 repeatForever 或符号动效：后两者每帧都在 App 进程里重算，
/// 列表里有几个在工作的会话时，静止不动也要占约 9% CPU；CA 的动画交给渲染服务，App 进程不参与，离屏不画。
/// 减弱动态效果时由调用方不放它（或换成静止的样子）；省电模式看 `LowPowerMode`。
struct LoopLayer {
    enum Kind: Equatable {
        /// 一圈淡轨道上一段弧匀速转，1.1s 一圈；线宽是直径的 14%。
        case orbit
        /// Cue 在做事时头像外的状态环：淡轨道上一颗圆头拖着由浓到淡的尾巴（约六成圈）匀速绕着走，1.6s 一圈。
        /// 尾巴是锥形渐变裁成环（缓存成位图，渲染服务每帧只转一层），头是与线同宽的圆点，盖住尾巴在渐变接缝处的直切口。
        /// 头不加光晕：光晕在浅色底上是一团糊边，头尾不干净。
        case comet(lineWidth: CGFloat)
        /// 心电线：淡色的一段心电波形上，一截实色沿波形从左走到右，1.4s 一趟；线宽是边长的 9%，淡波形是三成的颜色。
        case heartbeat
        /// 话在路上：一架纸飞机（与发送钮、"已送达"同一架，`Icon.send`）从左下飞进来、在正中停一下、朝机头的右上飞出去，裁在自己的框里，
        /// 一趟 `Flight.period` 秒。"发出"一族只有纸飞机：发送中、已送达都是它，燕尾箭只表示方向。
        /// 不播时（截图、减弱动态效果由调用方换静止符号、Mac 不在前台时只画的那一帧）停在正中。
        case flight
        /// 一圈细线从内切圆的大小往外扩到 1.6 倍、淡到看不见，2.4s 一次；线宽是边长的 7%。
        case ripple
        /// 一道横向的光带（宽是整体的一半）从左外扫到右外，1.8s 一趟。
        case sheen
        /// 铺满的一层颜色从无到有再回去，一明一暗 1.4s（盖在内容上，内容看起来在呼吸）。
        case pulse
        /// 一张图（等比铺满）上下浮动 `lift`，一上一下 1.8s。
        case float(CGImage, lift: CGFloat = 8)
        /// 一条预先画好的周期线（几层同一个周期）整条匀速横移一个周期，渲染服务只挪一层（`WaveStrip`）。
        case wave(WaveStrip)
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
        private var displayScale: CGFloat { traitCollection.displayScale }
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
        private var displayScale: CGFloat { window?.backingScaleFactor ?? 2 }
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
                mask.frame = plane.bounds
                mask.contents = Self.plane(side: side, scale: displayScale)
                if let fly = plane.animation(forKey: "loop")?.copy() as? CAAnimationGroup {
                    fly.animations = Self.flightPath(side: side)
                    plane.add(fly, forKey: "loop")
                }
            case .heartbeat, .ripple:
                loop.frame = bounds
                let side = min(bounds.width, bounds.height)
                let paths = Self.strokes(kind, side: side)
                for (index, shape) in (loop.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
                    shape.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
                    shape.path = paths[index]
                    shape.lineWidth = side * (kind == .ripple ? 0.07 : 0.09)
                    // 心电线的第一层是垫底的淡波形
                    shape.strokeColor = kind == .heartbeat && index == 0 ? color?.copy(alpha: (color?.alpha ?? 1) * 0.3) : color
                }
            case .comet(let width):
                layoutComet(loop, in: bounds, width: width)
            case .pulse:
                loop.frame = bounds
                loop.backgroundColor = color
            case .float:
                loop.frame = bounds
            case .wave(let wave):
                wave.layout(loop, in: bounds, color: color)
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

        /// 彗星的几层：轨道、裁成环的锥形渐变（尾巴）、头。头在渐变终点（角度 0，正右方），与尾巴一起随外层转。
        private func layoutComet(_ loop: CALayer, in bounds: CGRect, width: CGFloat) {
            loop.frame = bounds
            guard let color, let layers = loop.sublayers, layers.count == 3,
                  let track = layers[0] as? CAShapeLayer, let tail = layers[1] as? CAGradientLayer, let head = layers[2] as? CAShapeLayer
            else { return }
            let ring = CGPath(ellipseIn: bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
            track.frame = bounds
            track.path = ring
            track.lineWidth = width
            track.strokeColor = color.copy(alpha: color.alpha * 0.18)
            tail.frame = bounds
            tail.colors = [color.copy(alpha: 0), color.copy(alpha: 0), color].compactMap { $0 }
            let mask = (tail.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = bounds
            mask.path = ring
            mask.lineWidth = width
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 0, alpha: 1)
            tail.mask = mask
            // 尾巴缓存成位图：外层转的只是这张图，渲染服务不再每帧按遮罩离屏重画渐变
            tail.shouldRasterize = true
            tail.rasterizationScale = displayScale
            let dot = CGRect(x: bounds.maxX - width, y: bounds.midY - width / 2, width: width, height: width)
            head.frame = bounds
            head.path = CGPath(ellipseIn: dot, transform: nil)
            head.fillColor = color
        }

        private static func make(_ kind: Kind) -> CALayer {
            switch kind {
            case .comet:
                let layer = CALayer()
                let track = CAShapeLayer()
                track.fillColor = nil
                let tail = CAGradientLayer()
                tail.type = .conic
                tail.startPoint = CGPoint(x: 0.5, y: 0.5)
                tail.endPoint = CGPoint(x: 1, y: 0.5)
                tail.locations = [0, 0.4, 1]
                let head = CAShapeLayer()
                for sublayer in [track, tail, head] { layer.addSublayer(sublayer) }
                // 头在渐变终点上，顺着角度增大的方向转：头在前、尾巴跟着（层坐标里渐变与旋转同向，两端一样）
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = Double.pi * 2
                spin.duration = 1.6
                spin.timingFunction = CAMediaTimingFunction(name: .linear)
                return loop(spin, on: layer)
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
            case .flight:
                let layer = CALayer()
                layer.masksToBounds = true
                let plane = CALayer()
                plane.mask = CALayer()
                let fly = CAAnimationGroup()
                fly.duration = Flight.period
                layer.addSublayer(loop(fly, on: plane))
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
            case .wave(let wave):
                let layer = wave.make()
                _ = loop(wave.drift(), on: layer.sublayers![0])
                return layer
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

        /// 只描边、圆头圆角的一层（心电线、波纹）。
        private static func stroke() -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            return shape
        }

        /// 形状类动效每一层的路径（心电线、波纹，都是描边），画在边长 `side` 的正方形里（设计稿是 22 × 22、y 朝下的格子）。
        /// macOS 的层 y 朝上，统一翻过来，否则箭头朝下、心电线上下颠倒。
        private static func strokes(_ kind: Kind, side: CGFloat) -> [CGPath] {
            let unit = side / 22
            func path(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points.map { point in
                    #if os(macOS)
                    CGPoint(x: point.x * unit, y: (22 - point.y) * unit)
                    #else
                    CGPoint(x: point.x * unit, y: point.y * unit)
                    #endif
                })
                return path
            }
            switch kind {
            case .heartbeat:
                let wave = path([CGPoint(x: 1, y: 11), CGPoint(x: 5.5, y: 11), CGPoint(x: 7.5, y: 4.5), CGPoint(x: 11, y: 17.5),
                                 CGPoint(x: 13.5, y: 8), CGPoint(x: 15, y: 11), CGPoint(x: 21, y: 11)])
                return [wave, wave]
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
