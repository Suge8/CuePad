import QuartzCore
import SwiftUI

/// 头像的帧序列（`LoopLayer.Kind.sprite`）与等子代理交回的两颗点（`relay`）：都交给渲染服务，App 进程只在换拍子时建一次。
/// 宿主层的坐标两端都是 y 朝下（Mac 的宿主翻过来，`LoopLayer.Host.isFlipped`），这里不分平台。
extension LoopLayer {
    /// 头像的帧序列：颜色对它没有意义；`intro` 见 `LoopLayer.intro`。
    init(sprite: CueSprite, sheet: CueAtlas.Sheet, intro: Bool) { self.init(kind: .sprite(sprite, sheet), color: .clear, intro: intro) }
}

extension LoopLayer.Host {
    /// 小人：一层，`contents` 是整张拼图（`CueAtlas`），帧序列只按 `contentsRect` 离散地换（`CAKeyframeAnimation`，`discrete`）：两下之间值不变，
    /// 渲染服务与 App 都没有活；换进做完的那一下先放一遍 `intro`，在听的倾在同一层上以脚底为轴。
    static func makeSprite(_ sprite: CueSprite, on sheet: CueAtlas.Sheet, intro: Bool) -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.contents = sheet.image
        layer.contentsRect = sheet.rects[sprite.beat.still] ?? .zero
        let frames = flip(sprite.loop, in: sheet)
        if sprite.leans {
            let lean = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let angle = Motion.Beat.lean * .pi / 180
            lean.values = [0, -angle, 0]
            lean.keyTimes = [0, 0.5, 1]
            lean.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 2)
            lean.duration = Motion.Beat.leanPeriod
            let cycle = CAAnimationGroup()
            cycle.duration = frames?.duration ?? lean.duration
            lean.repeatCount = Float(cycle.duration / lean.duration)
            cycle.animations = [frames, lean].compactMap { $0 }
            _ = Self.loop(cycle, on: layer)
        } else if let frames {
            _ = Self.loop(frames, on: layer)
        }
        if intro, let intro = flip(sprite.intro, in: sheet) {
            // 进来这一下从此刻起放，不对齐全局的节拍
            intro.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            intro.isRemovedOnCompletion = true
            layer.add(intro, forKey: "intro")
        }
        return layer
    }

    /// 一串帧的 `contentsRect` 离散关键帧（离散模式的时刻比值多一个：每帧从哪一刻起，最后一个是 1）；不到两帧为 nil。
    private static func flip(_ frames: [CueSprite.Frame], in sheet: CueAtlas.Sheet) -> CAKeyframeAnimation? {
        let rects = frames.compactMap { sheet.rects[$0.asset] }
        guard rects.count > 1, rects.count == frames.count else { return nil }
        let total = frames.reduce(0) { $0 + $1.time }
        var at = 0.0
        let flip = CAKeyframeAnimation(keyPath: "contentsRect")
        flip.calculationMode = .discrete
        flip.values = rects.map(rectValue)
        flip.keyTimes = ([0] + frames.map { at += $0.time; return at / total }).map { NSNumber(value: $0) }
        flip.duration = total
        return flip
    }

    /// 摆在框里、以脚底为轴（在听的倾绕脚底转）。
    static func layoutSprite(_ layer: CALayer, in bounds: CGRect) {
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.bounds = CGRect(origin: .zero, size: bounds.size)
        layer.position = CGPoint(x: bounds.midX, y: bounds.maxY)
    }

    /// 等子代理交回：一颗大点（会话）在正中，一颗小点（子代理）任何时刻都在：出去、停一下、回来贴住大点，大点接住时鼓一下，再出去。
    /// 不并进去（并进去那几成时间里只剩一颗，读成待回复的墨点），也不绕着转（绕圈读成加载），不是线（线是在跑）。
    static func makeRelay() -> CALayer {
        let layer = CALayer()
        let home = CALayer(), away = CALayer()
        for dot in [home, away] { layer.addSublayer(dot) }
        let trip = CAKeyframeAnimation(keyPath: "transform.translation")
        trip.keyTimes = RelayMark.tripTimes
        trip.timingFunctions = [.init(controlPoints: 0.3, 0, 0.2, 1), .init(name: .linear), .init(controlPoints: 0.5, 0, 0.3, 1), .init(name: .linear)]
        trip.duration = RelayMark.period
        _ = loop(trip, on: away)
        let catchIt = CAKeyframeAnimation(keyPath: "transform.scale")
        catchIt.values = [1, 1, RelayMark.bulge, 1, 1]
        catchIt.keyTimes = RelayMark.catchTimes
        catchIt.duration = RelayMark.period
        _ = loop(catchIt, on: home)
        return layer
    }

    /// 两颗点的大小与位置随边长（小点的来回按此刻的边长重挂，边长没变不重挂：每次更新都重挂的话走到一半的那一趟从头再走）。
    static func layoutRelay(_ layer: CALayer, in bounds: CGRect, color: CGColor?) {
        layer.frame = bounds
        guard let home = layer.sublayers?.first, let away = layer.sublayers?.last else { return }
        let side = min(bounds.width, bounds.height)
        let big = side * RelayMark.big, small = side * RelayMark.small
        let resized = home.bounds.width != big
        for (dot, diameter) in [(home, big), (away, small)] {
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = color
        }
        home.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // 小点的模型位置在外面（右上）；贴住时沿对角线往回挪到两圆相切
        let out = side * RelayMark.reach, touch = (big + small) / 2 / 2.squareRoot()
        away.position = CGPoint(x: bounds.midX + out, y: bounds.midY - out)
        guard resized, let trip = away.animation(forKey: "loop")?.copy() as? CAKeyframeAnimation else { return }
        let back = touch - out
        trip.values = [CGSize.zero, .zero, CGSize(width: back, height: -back), CGSize(width: back, height: -back), .zero].map(sizeValue)
        away.add(trip, forKey: "loop")
    }
}

/// 等子代理交回那两颗点的几何与节拍（`LoopLayer` 的 `relay`）：静止时画同比例的符号 `Icon.relay`（design/tools/cue-symbols.py 的 `relay`）。
nonisolated enum RelayMark {
    /// 大点、小点的直径，小点心离正中多远（横竖各一份），都是边长的比例。
    static let big: CGFloat = 0.44
    static let small: CGFloat = 0.26
    static let reach: CGFloat = 0.34
    static let period = 2.4
    /// 小点：在外面停着 → 回来（缓入缓出）→ 贴住 → 出去，各段的起点。
    static let tripTimes: [NSNumber] = [0, 0.4, 0.62, 0.86, 1]
    /// 大点在小点贴上的那一下鼓到 `bulge` 倍。
    static let bulge = 1.18
    static let catchTimes: [NSNumber] = [0, 0.6, 0.68, 0.8, 1]
}

private func sizeValue(_ size: CGSize) -> NSValue {
    #if os(macOS)
    NSValue(size: size)
    #else
    NSValue(cgSize: size)
    #endif
}

private func rectValue(_ rect: CGRect) -> NSValue {
    #if os(macOS)
    NSValue(rect: rect)
    #else
    NSValue(cgRect: rect)
    #endif
}
