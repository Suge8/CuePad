import QuartzCore
import SwiftUI

/// 看板线"现在"那一截在跑时的样子（`BoardLine`）：几何、节奏与 Core Animation 的层只在这里，静止时画同一条线（`still`）。坐标 y 朝下，高 `height`，线绕中线走。
/// - 没派子代理：一条预先画好的周期线（按在干的活挑，`BoardPulse.Gait`），整条匀速横移一个周期；
/// - 派了子代理：不起伏，从左端圆弧分出每个在跑的子代理一条直轨（地铁图那样分岔、等距平行），轨是淡的底线，
///   上面一小截亮的匀速往前跑（只动虚线相位，各轨错开），几条轨就是几路在做。
/// 两种都只交给 Core Animation（`LoopLayer` 的 `wave`）：线不逐帧重画，App 进程不参与。
nonisolated struct WaveStrip: Equatable, Sendable {
    let gait: BoardPulse.Gait
    let tracks: Int

    static let period: CGFloat = 120
    static let height: CGFloat = 12
    static let line: CGFloat = 1.5
    static let laneLine: CGFloat = 1.3
    static let laneGap: CGFloat = 4
    /// 分岔那一截多宽。
    static let fork: CGFloat = 14
    /// 每条轨上跑的那一小截与它后面的空。
    static let dash: [CGFloat] = [8, 40]
    static let laneSeconds = 1.6
    static let laneOpacity: CGFloat = 0.28

    private var mid: CGFloat { Self.height / 2 }
    var lineWidth: CGFloat { tracks > 0 ? Self.laneLine : Self.line }

    /// 横移一个周期要几秒：用工具快，压缩次之，在想慢。
    private var seconds: Double {
        switch gait {
        case .think: 6
        case .tool: 3
        case .compact: 4
        }
    }

    /// 周期线在一个周期里 x 处的高度。
    private func y(_ x: CGFloat) -> CGFloat {
        let turn = 2 * CGFloat.pi * x / Self.period
        switch gait {
        case .think: return mid - 1.4 * sin(turn * 2) - 0.5 * sin(turn * 5)
        case .compact: return mid - 1.1 * sin(turn * 10)
        case .tool:
            // 平线上几个宽窄不一的圆鼓包（高斯形）：中心、宽、高
            let bumps: [(CGFloat, CGFloat, CGFloat)] = [(18, 5, 2.6), (52, 4, 1.5), (64, 5, 3), (98, 6, 2.2)]
            return bumps.reduce(mid + 1) { y, bump in y - bump.2 * exp(-pow((x - bump.0) / bump.1, 2)) }
        }
    }

    /// 周期线从 0 画到 `width`，周期接周期地铺。
    private func main(width: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y(0)))
            for x in stride(from: CGFloat(2), through: width, by: 2) {
                path.addLine(to: CGPoint(x: x, y: y(x.truncatingRemainder(dividingBy: Self.period))))
            }
        }
    }

    /// 第 `index` 条子代理轨：从左端中线圆弧分到自己那一层，再平直到 `width`。
    private func lane(_ index: Int, width: CGFloat) -> Path {
        let y = mid + (CGFloat(index) - CGFloat(tracks - 1) / 2) * Self.laneGap
        return Path { path in
            path.move(to: CGPoint(x: 0, y: mid))
            path.addCurve(to: CGPoint(x: Self.fork, y: y), control1: CGPoint(x: Self.fork * 0.55, y: mid), control2: CGPoint(x: Self.fork * 0.45, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
    }

    /// 静止时的线（同一条，不动；子代理轨画成实线）。
    var still: some Shape { WaveLine(strip: self) }

    // MARK: Core Animation（`LoopLayer.Kind.wave`）

    /// 外层裁掉看不见的部分。周期线：里面一条比可见宽多一个周期的带子；子代理轨：每条一层淡底线、一层跑的短划。
    func make() -> CALayer {
        let layer = CALayer()
        layer.masksToBounds = true
        let band = CALayer()
        for index in 0..<max(tracks * 2, 1) {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.lineWidth = lineWidth
            if tracks > 0, !index.isMultiple(of: 2) { shape.lineDashPattern = Self.dash.map { $0 as NSNumber } }
            band.addSublayer(shape)
        }
        layer.addSublayer(band)
        return layer
    }

    /// 要循环的动画与它挂在哪一层：周期线整条横移一个周期，子代理轨各自的短划往前跑（相位错开）。
    func loops(in layer: CALayer) -> [(CAAnimation, CALayer)] {
        guard let band = layer.sublayers?.first, let shapes = band.sublayers else { return [] }
        guard tracks > 0 else {
            let drift = CABasicAnimation(keyPath: "transform.translation.x")
            drift.fromValue = 0
            drift.toValue = -Self.period
            drift.duration = seconds
            drift.timingFunction = CAMediaTimingFunction(name: .linear)
            return [(drift, band)]
        }
        let cycle = Self.dash.reduce(0, +)
        return (0..<tracks).map { index in
            let offset = cycle * CGFloat(index) / CGFloat(tracks)
            let flow = CABasicAnimation(keyPath: "lineDashPhase")
            flow.fromValue = cycle + offset
            flow.toValue = offset
            flow.duration = Self.laneSeconds
            flow.timingFunction = CAMediaTimingFunction(name: .linear)
            return (flow, shapes[index * 2 + 1])
        }
    }

    func layout(_ layer: CALayer, in bounds: CGRect, color: CGColor?) {
        layer.frame = bounds
        guard let band = layer.sublayers?.first else { return }
        let width = tracks > 0 ? bounds.width : bounds.width + Self.period
        band.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        // macOS 的层 y 朝上：翻过来，线不上下颠倒
        #if os(macOS)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        #else
        var flip = CGAffineTransform.identity
        #endif
        for (index, shape) in (band.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
            shape.frame = band.bounds
            let path = tracks > 0 ? lane(index / 2, width: width) : main(width: width)
            shape.path = path.cgPath.copy(using: &flip)
            let base = tracks > 0 && index.isMultiple(of: 2)
            shape.strokeColor = base ? color?.copy(alpha: (color?.alpha ?? 1) * Self.laneOpacity) : color
        }
    }

    fileprivate func path(width: CGFloat) -> Path {
        guard tracks > 0 else { return main(width: width) }
        return Path { path in
            for index in 0..<tracks { path.addPath(lane(index, width: width)) }
        }
    }
}

nonisolated private struct WaveLine: Shape {
    let strip: WaveStrip

    func path(in rect: CGRect) -> Path { strip.path(width: rect.width) }
}
