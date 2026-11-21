import QuartzCore
import SwiftUI

/// 思考场：一层横着的渐变打底，上面两团径向的光各沿一个椭圆绕，周期互不成整数比，叠出来的色一直在翻、不显出重复。
/// 档越高绕得越快、圈越大、光越浓。否决过：SwiftUI 的网格渐变按帧重算——气泡开着时 App 进程一直占约 5% CPU，换成这里渲染服务画，App 不参与。
extension LoopLayer.Host {
    static func makeField() -> CALayer {
        let layer = CALayer()
        layer.masksToBounds = true
        let base = CAGradientLayer()
        base.startPoint = CGPoint(x: 0, y: 0.5)
        base.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(base)
        for _ in 0..<2 {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(glow)
        }
        return layer
    }

    static func layoutField(_ layer: CALayer, in bounds: CGRect, energy: Double, stops: [CGColor]) {
        guard let sublayers = layer.sublayers, sublayers.count == 3, stops.count == 5 else { return }
        let resized = layer.frame != bounds
        layer.frame = bounds
        (sublayers[0] as? CAGradientLayer)?.colors = Array(stops[0..<3])
        sublayers[0].frame = layer.bounds
        let side = bounds.height * (1.6 + 1.2 * energy)
        let reach = CGSize(width: bounds.width * (0.12 + 0.3 * energy), height: bounds.height * (0.12 + 0.25 * energy))
        let period = 9 - 6 * energy
        for (index, glow) in sublayers.dropFirst().compactMap({ $0 as? CAGradientLayer }).enumerated() {
            let color = stops[3 + index]
            glow.colors = [color.copy(alpha: 0.35 + 0.5 * energy) ?? color, color.copy(alpha: 0) ?? color]
            glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            // 两团从相对的两头起、一冷一暖，各绕各的圈
            let center = CGPoint(x: bounds.width * (index == 0 ? 0.3 : 0.7), y: bounds.midY)
            glow.position = center
            guard resized || glow.animation(forKey: "loop") == nil else { continue }
            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.path = CGPath(ellipseIn: CGRect(x: center.x - reach.width, y: center.y - reach.height, width: reach.width * 2, height: reach.height * 2), transform: nil)
            orbit.calculationMode = .paced
            orbit.duration = period * (index == 0 ? 1 : 1.37)
            _ = loop(orbit, on: glow)
        }
    }
}
