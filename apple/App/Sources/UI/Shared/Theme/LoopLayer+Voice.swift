import QuartzCore
import SwiftUI

/// 声纹的绘制参数，不持有通话生命周期。十三根墨线始终是同一批图层：连接时围拢，听说时展开，静音和结束时收束。
/// 待连接与处理的光沿环行走只是等待信号；听说的起伏只来自音轨，静置没有假音量循环。
struct VoiceRibbon: Equatable {
    let activity: CueVoiceActivity?
    let muted: Bool
    let samples: [CGFloat]
    let playing: Bool
    let reduced: Bool

    var quiet: Bool { muted && activity != .speaking }
    var orbiting: Bool { activity == .connecting || activity == .processing }
    var waiting: Bool { playing && orbiting && !quiet }

    func height(at index: Int) -> CGFloat {
        let center = CGFloat(index) / CGFloat(VoiceRibbonLayer.count - 1)
        let shoulder = abs(sin(center * .pi * 2))
        if quiet { return 0.07 }
        switch activity {
        case nil, .idle, .ended: return 0.08 + shoulder * 0.12
        case .closing: return 0.07 + shoulder * 0.05
        case .failed: return 0.12 + shoulder * 0.22
        case .connecting, .processing: return 0.16
        case .listening, .speaking:
            // 一根对应最近一个采样；尚未填满的左侧为空，不把起步的几帧拉伸到整条宽度。
            let slot = samples.count - VoiceRibbonLayer.count + index
            let sample = slot >= 0 && slot < samples.count ? samples[slot] : 0
            return 0.10 + shoulder * (0.20 + min(1, max(0, sample)) * 0.68)
        }
    }
}

/// 只在状态或采样到达时提交目标，逐帧插值交给渲染服务。每条被打断的过渡从 presentation layer 接续，不延后业务状态。
final class VoiceRibbonLayer: CALayer {
    nonisolated static let count = 13
    private static let stroke: CGFloat = 2.4
    private static let orbitRadius: CGFloat = 0.34
    private static let period = 1.8
    private static let lightSteps = 24
    private var waiting = false
    private var installed = false

    nonisolated override init() {
        super.init()
        for _ in 0..<Self.count {
            let rib = CAShapeLayer()
            addSublayer(rib)
        }
    }

    nonisolated override init(layer: Any) { super.init(layer: layer) }
    nonisolated required init?(coder: NSCoder) { fatalError() }

    func show(_ ribbon: VoiceRibbon, in bounds: CGRect, color: CGColor?) {
        frame = bounds
        let animate = installed && ribbon.playing && !ribbon.reduced
        for (index, rib) in (sublayers ?? []).enumerated() {
            guard let shape = rib as? CAShapeLayer else { continue }
            let fraction = CGFloat(index) / CGFloat(Self.count - 1)
            let angle = CGFloat(index) / CGFloat(Self.count) * .pi * 2 - .pi / 2
            let orbit = ribbon.orbiting && !ribbon.quiet
            let radius = bounds.height * Self.orbitRadius
            let point = orbit
                ? CGPoint(x: bounds.width / 2 + cos(angle) * radius, y: bounds.height / 2 + sin(angle) * radius)
                : CGPoint(x: Self.stroke / 2 + fraction * (bounds.width - Self.stroke), y: bounds.height / 2)
            let height = max(Self.stroke, bounds.height * ribbon.height(at: index))
            let path = CGPath(roundedRect: CGRect(x: -Self.stroke / 2, y: -height / 2, width: Self.stroke, height: height),
                              cornerWidth: Self.stroke / 2, cornerHeight: Self.stroke / 2, transform: nil)
            redirect(shape, key: "position", to: point, animate: animate)
            redirect(shape, key: "path", to: path, animate: animate)
            redirect(shape, key: "transform", to: CATransform3DMakeRotation(orbit ? angle + .pi / 2 : 0, 0, 0, 1), animate: animate)
            redirect(shape, key: "fillColor", to: color, animate: installed && ribbon.playing)
            if waiting != ribbon.waiting || !installed { light(shape, index: index, playing: ribbon.waiting, animate: animate) }
        }
        waiting = ribbon.waiting
        installed = true
        DebugHooks.voiceRibbon(ribbon, on: self)
    }

    private func redirect(_ layer: CALayer, key: String, to value: Any?, animate: Bool) {
        let old = layer.value(forKeyPath: key) as? NSObject
        let next = value as? NSObject
        if !animate { layer.removeAnimation(forKey: key) }
        guard old != next else { return }
        let shown = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        if animate {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = shown
            move.toValue = value
            // 电平每 50ms 到来，缓出让第一帧就跟随；空间展开仍用同一条 glide，不让采样重启位移动画。
            let followsSample = key == "path" || key == "fillColor"
            move.duration = followsSample ? Motion.Fade.duration : Motion.Glide.duration
            move.timingFunction = followsSample ? Motion.Fade.timing : Motion.Glide.timing
            layer.add(move, forKey: key)
        } else {
            layer.removeAnimation(forKey: key)
        }
    }

    private func light(_ shape: CAShapeLayer, index: Int, playing: Bool, animate: Bool) {
        let shown = shape.presentation()?.opacity ?? shape.opacity
        shape.removeAnimation(forKey: "loop")
        shape.removeAnimation(forKey: "settle")
        shape.opacity = 1
        var current: Float = 1
        if playing {
            let walk = CAKeyframeAnimation(keyPath: "opacity")
            let phase = Double(index) / Double(Self.count) * .pi * 2
            let values = (0...Self.lightSteps).map { step in
                0.35 + 0.65 * (1 + sin(Double(step) / Double(Self.lightSteps) * .pi * 2 - phase)) / 2
            }
            walk.isAdditive = true
            walk.values = values.map { $0 - 1 }
            walk.duration = Self.period
            _ = LoopLayer.Host.loop(walk, on: shape)
            let elapsed = shape.convertTime(CACurrentMediaTime(), from: nil) - walk.beginTime
            let sample = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period * Double(Self.lightSteps)
            let lower = Int(sample)
            current = Float(values[lower] + (values[lower + 1] - values[lower]) * (sample - Double(lower)))
        }
        if animate {
            let settle = CABasicAnimation(keyPath: "opacity")
            // 循环保持全局相位；把当前亮度与该相位的差淡去，避免重入时旧 settle 结束后突然闪亮。
            settle.isAdditive = playing
            settle.fromValue = playing ? shown - current : shown
            settle.toValue = playing ? 0 : 1
            settle.duration = Motion.Fade.duration
            settle.timingFunction = Motion.Fade.timing
            shape.add(settle, forKey: "settle")
        }
    }
}
