import QuartzCore
import SwiftUI

/// Cue 在听、在想时从输入框后面升起的那片光（`CueGlow`）：几团压在底边上的椭圆光各自左右漂、各自明暗，周期互不成倍，
/// 叠起来不重复、看不出一个循环。只动位移与透明度，交给渲染服务；一层底色不动，光团漂开时底边也不露空。
/// 否决过：整圈屏幕边光（Siri 那种）——说的是"整台设备在听"，这里只是 Cue 这一页在忙；一团光左右扫——读成进度条。
extension LoopLayer.Host {
    private struct Blob {
        let x: CGFloat, width: CGFloat, height: CGFloat
        let drift: CGFloat, driftPeriod: Double
        let dim: Float, breathPeriod: Double
    }

    private static let blobs = [
        Blob(x: 0.5, width: 1.3, height: 0.9, drift: 18, driftPeriod: 7.3, dim: 0.75, breathPeriod: 3.1),
        Blob(x: 0.26, width: 0.8, height: 0.7, drift: 42, driftPeriod: 5.3, dim: 0.35, breathPeriod: 2.3),
        Blob(x: 0.76, width: 0.75, height: 0.6, drift: 36, driftPeriod: 6.1, dim: 0.4, breathPeriod: 3.7),
    ]

    static func makeGlow() -> CALayer {
        let layer = CALayer()
        for blob in blobs {
            let light = CAGradientLayer()
            light.type = .radial
            light.startPoint = CGPoint(x: 0.5, y: 0.5)
            light.endPoint = CGPoint(x: 1, y: 1)
            light.locations = [0, 0.45, 1]
            let drift = CABasicAnimation(keyPath: "transform.translation.x")
            drift.fromValue = -blob.drift
            drift.toValue = blob.drift
            drift.duration = blob.driftPeriod
            drift.autoreverses = true
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = blob.dim
            breathe.toValue = 1
            breathe.duration = blob.breathPeriod
            breathe.autoreverses = true
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            _ = loop(drift, on: light, key: "drift")
            layer.addSublayer(loop(breathe, on: light, key: "breathe"))
        }
        return layer
    }

    static func layoutGlow(_ layer: CALayer, in bounds: CGRect, color: CGColor?) {
        layer.frame = bounds
        guard let color else { return }
        let colors = [color, color.copy(alpha: color.alpha * 0.35), color.copy(alpha: 0)].compactMap { $0 }
        for (light, blob) in zip(layer.sublayers ?? [], blobs) {
            guard let light = light as? CAGradientLayer else { continue }
            // 圆心压在底边上：只露出上半个椭圆，像从底下照上来
            light.bounds = CGRect(x: 0, y: 0, width: bounds.width * blob.width, height: bounds.height * blob.height * 2)
            light.position = CGPoint(x: bounds.width * blob.x, y: bounds.maxY)
            light.colors = colors
        }
    }
}

/// Cue 在听、在想（`CueBeat.dot == .moving`）时铺在 Cue 页底下的光：对话在它上面滚。光的底边压在输入框那一叠（`FloatingReply`）上沿下面一截，
/// 从那一叠后面透出来——压在屏幕底边的话，拍板卡升起来就整片盖住了。
/// 不放循环动效时（减弱动态效果、省电、页不在前台）是同一片光静止的样子。
struct CueGlow: View {
    let on: Bool
    @LoopsPlay private var plays
    @Environment(\.palette) private var palette
    @Environment(\.chatBottomInset) private var replyInset

    static let height: CGFloat = 420
    /// 光的底边伸进输入框那一叠多深：那一叠是玻璃，伸进去的这截把它的上沿也照亮。
    static let tuck: CGFloat = 20

    var body: some View {
        ZStack {
            if on {
                Group {
                    if plays {
                        LoopLayer(kind: .glow, color: palette.glow)
                    } else {
                        EllipticalGradient(colors: [palette.glow, palette.glow.opacity(0)], center: .bottom, endRadiusFraction: 0.5)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .padding(.bottom, max(0, replyInset - Self.tuck))
        .animation(on ? Motion.Glow.rise : Motion.Glow.fall, value: on)
        .allowsHitTesting(false)
        .readerHidden(true)
    }
}
