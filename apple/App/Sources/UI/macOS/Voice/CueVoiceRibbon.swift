#if os(macOS)
import SwiftUI

/// 同一张闭合声纹的等距截线：所有截线共享实际采样，只有截面厚度与透视不同。
/// 不读时钟、不补噪声；无采样时只有静态形态。固定三次曲线拓扑让新采样与插话可从当前路径连续变形。
nonisolated enum CueVoiceRibbon {
    enum Form { case inward, outward, waiting, quiet
        var isAudio: Bool { self == .inward || self == .outward }
    }

    static let strands = 14
    static let sampleCount = 32
    private static let vertices = 80
    private static let innerDiameter: CGFloat = 130

    static func path(form: Form, samples: [CGFloat], strand: Int, in bounds: CGRect) -> CGPath {
        let lane = CGFloat(strand) / CGFloat(strands - 1)
        let points = (0..<vertices).map { index in
            point(angle: CGFloat(index) / CGFloat(vertices) * .pi * 2, lane: lane, form: form, samples: samples, center: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in 0..<vertices {
            let previous = points[(index + vertices - 1) % vertices], start = points[index]
            let end = points[(index + 1) % vertices], next = points[(index + 2) % vertices]
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + (end.x - previous.x) / 6, y: start.y + (end.y - previous.y) / 6),
                          control2: CGPoint(x: end.x - (next.x - start.x) / 6, y: end.y - (next.y - start.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    private static func point(angle: CGFloat, lane: CGFloat, form: Form, samples: [CGFloat], center: CGPoint) -> CGPoint {
        let audio = form.isAudio ? amplitude(at: angle, samples: samples) : 0
        let outward = form == .outward
        // 截线在两侧展开、在斜对角汇成一道脊；是一张带状曲面，不是独立的圆。
        let spread = form.isAudio ? 9 + 16 * pow(sin(angle + .pi / 4), 2) : 7
        let fold = form.isAudio ? (sin(angle * 2) + 0.35 * cos(angle * 3)) * (outward ? 8 : 4) : 0
        let displacement = audio * (outward ? 16 : -12)
        let r = innerDiameter / 2 + lane * spread + fold + displacement
        let xScale: CGFloat = form == .inward ? 1.25 : 1
        let yScale: CGFloat = form == .inward ? 0.73 : 0.9
        let twist = form.isAudio ? (lane - 0.5) * 0.16 : 0
        return CGPoint(x: center.x + cos(angle + twist) * r * xScale,
                       y: center.y + sin(angle + twist) * r * yScale)
    }

    /// 把线性的短历史镜像包回一圈，接缝处不会把最后一项硬接到第一项；五点窗抑制尖刺。
    private static func amplitude(at angle: CGFloat, samples: [CGFloat]) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        let position = (1 - cos(angle)) * 0.5 * CGFloat(samples.count - 1)
        let index = Int(position), fraction = position - CGFloat(index)
        func smoothed(_ center: Int) -> CGFloat {
            (-2...2).reduce(CGFloat.zero) { sum, offset in
                sum + samples[min(samples.count - 1, max(0, center + offset))]
            } / 5
        }
        return smoothed(index) * (1 - fraction) + smoothed(min(index + 1, samples.count - 1)) * fraction
    }
}
#endif
