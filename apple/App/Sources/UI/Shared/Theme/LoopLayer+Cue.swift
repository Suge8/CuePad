import QuartzCore
import SwiftUI

/// 宿主层的坐标两端都是 y 朝下（Mac 的宿主翻过来，`LoopLayer.Host.isFlipped`），这里不分平台。
extension LoopLayer {
    init(sprite: CueSprite, sheet: CueAtlas.Sheet, intro: Bool) { self.init(kind: .sprite(sprite, sheet), color: .clear, intro: intro) }
}

extension LoopLayer.Host {
    /// 小人：一层，`contents` 是整张拼图（`CueAtlas`），帧序列只按 `contentsRect` 离散地换（`discrete`）：两下之间值不变。
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

    static func layoutSprite(_ layer: CALayer, in bounds: CGRect) {
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.bounds = CGRect(origin: .zero, size: bounds.size)
        layer.position = CGPoint(x: bounds.midX, y: bounds.maxY)
    }
}

/// 等子代理交回那两颗点的节拍（`StateInk` 的 `relay`）：两颗点的大小与位置是符号 `relay` 的（design/tools/ink/rounded/statuses.py），比例写在这里给小点来回算距离。
/// 不并进去（并进去那几成时间里只剩一颗，读成待回复的墨点），也不绕着转（绕圈读成加载）。
nonisolated enum RelayMark {
    static let big: CGFloat = 0.44
    static let small: CGFloat = 0.26
    static let reach: CGFloat = 0.34
    static let period = 2.4
    static let tripTimes: [Double] = [0, 0.4, 0.62, 0.86, 1]
    static let bulge = 1.18
    static let catchTimes: [Double] = [0, 0.6, 0.68, 0.8, 1]
}

private func rectValue(_ rect: CGRect) -> NSValue {
    #if os(macOS)
    NSValue(rect: rect)
    #else
    NSValue(cgRect: rect)
    #endif
}
