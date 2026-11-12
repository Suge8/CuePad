import QuartzCore
import SwiftUI

/// 回合条上"此刻这一轮"在跑时的那一节：一条淡的底，一道光从头走到尾。
/// 想的时候光长而慢，跑工具时短而快，压缩上下文时反着走（往回收）；有子代理在跑就分成几条细的，各走各的、错开。
nonisolated struct WaveStrip: Equatable, Sendable {
    let gait: BoardPulse.Gait
    let tracks: Int

    static let height: CGFloat = 12
    /// 回合条一节的粗细（过去的各节同粗，`BoardLine`）。
    static let bar: CGFloat = 4
    private static let lane: CGFloat = 2
    private static let laneGap: CGFloat = 2
    private static let baseOpacity: CGFloat = 0.2
    /// 光的头后面那一点收尾，占一节的几分之几：头不是一刀切的硬边。
    private static let edge = 0.03
    private static let frames = 24

    private var lanes: Int { max(tracks, 1) }
    private var thick: CGFloat { tracks > 0 ? Self.lane : Self.bar }

    private var comet: (seconds: Double, tail: Double) {
        switch gait {
        case .think: (2.6, 0.55)
        case .tool: (1.3, 0.3)
        case .compact: (1.8, 0.4)
        }
    }

    fileprivate func rects(in bounds: CGRect) -> [CGRect] {
        let total = CGFloat(lanes) * thick + CGFloat(lanes - 1) * Self.laneGap
        return (0..<lanes).map { CGRect(x: bounds.minX, y: bounds.midY - total / 2 + CGFloat($0) * (thick + Self.laneGap), width: bounds.width, height: thick) }
    }

    /// 不放动画时（排在后面的卡、省电、减弱动态）：底是轨道色，光停在靠右的一截。
    var still: some Shape { WaveBars(strip: self, head: false) }
    var head: some Shape { WaveBars(strip: self, head: true) }

    /// 光的三个色标（尾、头、头后的收尾）在头走到 `at` 时的位置。渐变层的色标只认 0…1，出界的夹住。
    private func stops(_ at: Double) -> [NSNumber] {
        [at - comet.tail, at, at + Self.edge].map { NSNumber(value: min(max($0, 0), 1)) }
    }

    // MARK: Core Animation（`LoopLayer.Kind.wave`）

    func make() -> CALayer {
        let layer = CALayer()
        for _ in 0..<lanes {
            let lane = CAGradientLayer()
            lane.startPoint = CGPoint(x: gait == .compact ? 1 : 0, y: 0.5)
            lane.endPoint = CGPoint(x: gait == .compact ? 0 : 1, y: 0.5)
            lane.locations = stops(0.7)
            lane.masksToBounds = true
            layer.addSublayer(lane)
        }
        return layer
    }

    func loops(in layer: CALayer) -> [(CAAnimation, CALayer)] {
        (layer.sublayers ?? []).enumerated().map { index, lane in
            let run = CAKeyframeAnimation(keyPath: "locations")
            // 头从左沿外走到尾也出了右沿：按帧给，夹过的两端之间直接插值的话尾巴一路是零长
            run.values = (0...Self.frames).map { stops(Double($0) / Double(Self.frames) * (1 + comet.tail + Self.edge)) }
            run.duration = comet.seconds
            run.timeOffset = comet.seconds * Double(index) / Double(lanes)
            return (run, lane)
        }
    }

    func layout(_ layer: CALayer, in bounds: CGRect, color: CGColor?) {
        layer.frame = bounds
        for (lane, rect) in zip(layer.sublayers ?? [], rects(in: CGRect(origin: .zero, size: bounds.size))) {
            lane.frame = rect
            lane.cornerRadius = rect.height / 2
            lane.backgroundColor = color?.copy(alpha: (color?.alpha ?? 1) * Self.baseOpacity)
            (lane as? CAGradientLayer)?.colors = [color?.copy(alpha: 0), color, color?.copy(alpha: 0)].compactMap { $0 }
        }
    }
}

nonisolated private struct WaveBars: Shape {
    let strip: WaveStrip
    let head: Bool
    /// 静止时光停在一节的哪一段。
    private static let rest: ClosedRange<CGFloat> = 0.45...0.8

    func path(in rect: CGRect) -> Path {
        Path { path in
            for lane in strip.rects(in: rect) {
                let bar = head ? CGRect(x: lane.minX + lane.width * Self.rest.lowerBound, y: lane.minY, width: lane.width * (Self.rest.upperBound - Self.rest.lowerBound), height: lane.height) : lane
                path.addRoundedRect(in: bar, cornerSize: CGSize(width: bar.height / 2, height: bar.height / 2))
            }
        }
    }
}
