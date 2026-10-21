import QuartzCore
import SwiftUI

/// 推进中卡下沿那条线（`BoardPulse.Trace`）：装饰，不对应真实事件。在跑的按在干的活挑一条预先画好的周期线，派了子代理的主线压扁到上沿、
/// 下面每个在跑的子代理一条细轨（长划短空、节奏各不相同，横移时看得出各走各的），最多 `maxTracks` 条、多的写 +N；停住的是一条平线、末端一个点；
/// 歇着的是一条淡灰实线（`track`），同线宽、不带点。
/// 动只靠整条横移一个周期，交给 Core Animation（`LoopLayer` 的 `wave`）：线不逐帧重画，App 进程不参与。
/// SwiftUI 的 repeatForever 偏移虽也不重画线，却每帧在 App 进程里重算动画与显示列表（同 `LoopLayer` 头注释的实测），一列几条就常驻占 CPU。
/// 只有看得见的在动：卡在懒加载栈里，出屏就不存在；页不在前台（`pageActive`）、窗口不是活跃窗口或场景到了后台、减弱动态效果、省电模式时静止；
/// 一列里排在第 `maxMoving` 条以后的静止（`moves` 由列按先后给）——"同屏最多几条"要逐行读几何才判得出，每行一个几何读数的开销比省下的动画还大，
/// 按列里的先后数是最轻的等价做法：列从上往下读，排在前面的就是一屏里先看到的。
struct BoardWave: View {
    let trace: BoardPulse.Trace
    /// 列里允许它动（排在前 `maxMoving` 条在跑的里）。
    var moves = true
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var pageActive
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    private var visible: Bool { appearsActive && pageActive }
    #else
    @Environment(\.scenePhase) private var scenePhase
    private var visible: Bool { scenePhase == .active && pageActive }
    #endif

    static let maxMoving = 8
    static let maxTracks = 3
    /// 停住与歇着的平线的线宽。
    private static let stoppedLine: CGFloat = 1.6

    var body: some View {
        switch trace {
        case .resting:
            StoppedLine(full: true).stroke(palette.track, lineWidth: Self.stoppedLine)
                .frame(height: WaveStrip.height)
                .accessibilityHidden(true)
        case .running(let gait, let subagents):
            let strip = WaveStrip(gait: gait, tracks: min(subagents, Self.maxTracks))
            HStack(spacing: 4) {
                Group {
                    if moves && visible && !reduceMotion && !LowPowerMode.shared.isOn {
                        LoopLayer(kind: .wave(strip), color: palette.signature)
                    } else {
                        ZStack {
                            strip.still.stroke(palette.signature, style: StrokeStyle(lineWidth: WaveStrip.line, lineCap: .round, lineJoin: .round))
                            WaveTracks(count: strip.tracks).stroke(palette.signature, lineWidth: WaveStrip.trackLine).opacity(WaveStrip.trackOpacity)
                        }
                    }
                }
                .frame(height: strip.height)
                .clipped()
                if subagents > Self.maxTracks {
                    Text("+\(subagents - Self.maxTracks)").font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.ink3)
                }
            }
            .accessibilityHidden(true)
        case .stopped(let stop):
            StoppedLine().stroke(tint(stop), style: StrokeStyle(lineWidth: Self.stoppedLine, lineCap: .round, dash: stop == .interrupted ? [10, 6] : []))
                .overlay(alignment: .trailing) { Circle().fill(tint(stop)).frame(width: 5.2, height: 5.2).padding(.trailing, 4.4) }
                .frame(height: WaveStrip.height)
                .accessibilityHidden(true)
        }
    }

    private func tint(_ stop: BoardPulse.Stop) -> Color {
        switch stop {
        case .failure: palette.failure
        case .interrupted, .quiet: palette.ink3
        }
    }
}

/// 一条预先画好的周期线与它的子代理细轨：几何、节奏与 Core Animation 的层只在这里，静止时画同一条线（`still`）。坐标 y 朝下，高 16（有细轨时 20）。
nonisolated struct WaveStrip: Equatable, Sendable {
    let gait: BoardPulse.Gait
    let tracks: Int

    static let period: CGFloat = 120
    static let height: CGFloat = 16
    static let line: CGFloat = 1.5
    static let trackLine: CGFloat = 1.2
    static let trackOpacity = 0.6
    /// 细轨的虚线节奏（长划短空），一条一种。
    static let dashes: [[CGFloat]] = [[16, 4], [11, 4], [20, 4]]

    var height: CGFloat { tracks > 0 ? 20 : Self.height }

    /// 横移一个周期要几秒：用工具快，压缩次之，在想与派了子代理的慢。
    var seconds: Double {
        if tracks > 0 { return 6 }
        return switch gait {
        case .think: 6
        case .tool: 3
        case .compact: 4
        }
    }

    /// 主线在一个周期里 x 处的高度。
    func y(_ x: CGFloat) -> CGFloat {
        let turn = 2 * CGFloat.pi * x / Self.period
        if tracks > 0 { return 4 - 1.1 * sin(turn * 2) - 0.4 * sin(turn * 5) }
        switch gait {
        case .think: return 10 - 1.8 * sin(turn * 2) - 0.7 * sin(turn * 5)
        case .compact: return 10 - 1.6 * sin(turn * 10)
        case .tool:
            // 平线上几个宽窄不一的尖峰：中心、半宽、高
            let peaks: [(CGFloat, CGFloat, CGFloat)] = [(18, 3, 7), (52, 2, 4), (61, 3, 8), (96, 4, 6)]
            return peaks.reduce(11) { y, peak in
                let k = 1 - abs(x - peak.0) / peak.1
                return k > 0 ? min(y, 11 - peak.2 * k) : y
            }
        }
    }

    /// 主线从 0 画到 `width`，周期接周期地铺。
    func main(width: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y(0)))
            for x in stride(from: CGFloat(2), through: width, by: 2) {
                path.addLine(to: CGPoint(x: x, y: y(x.truncatingRemainder(dividingBy: Self.period))))
            }
        }
    }

    /// 第 `index` 条细轨所在的高度。
    static func trackY(_ index: Int) -> CGFloat { 10.5 + CGFloat(index) * 3.5 }

    /// 静止时的主线（同一条，不动）。
    var still: some Shape { WaveLine(strip: self) }

    // MARK: Core Animation（`LoopLayer.Kind.wave`）

    /// 外层裁掉看不见的部分，里面一条比可见宽多一个周期的带子横移一个周期。
    func make() -> CALayer {
        let layer = CALayer()
        layer.masksToBounds = true
        let band = CALayer()
        for index in 0...tracks {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.lineWidth = index == 0 ? Self.line : Self.trackLine
            if index > 0 { shape.lineDashPattern = Self.dashes[index - 1].map { $0 as NSNumber } }
            band.addSublayer(shape)
        }
        layer.addSublayer(band)
        return layer
    }

    func drift() -> CAAnimation {
        let drift = CABasicAnimation(keyPath: "transform.translation.x")
        drift.fromValue = 0
        drift.toValue = -Self.period
        drift.duration = seconds
        drift.timingFunction = CAMediaTimingFunction(name: .linear)
        return drift
    }

    func layout(_ layer: CALayer, in bounds: CGRect, color: CGColor?) {
        layer.frame = bounds
        guard let band = layer.sublayers?.first else { return }
        let width = bounds.width + Self.period
        band.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        // macOS 的层 y 朝上：翻过来，线不上下颠倒
        #if os(macOS)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        #else
        var flip = CGAffineTransform.identity
        #endif
        for (index, shape) in (band.sublayers ?? []).compactMap({ $0 as? CAShapeLayer }).enumerated() {
            shape.frame = band.bounds
            let path = index == 0 ? main(width: width).cgPath : Path { line in
                line.move(to: CGPoint(x: 0, y: Self.trackY(index - 1)))
                line.addLine(to: CGPoint(x: width, y: Self.trackY(index - 1)))
            }.cgPath
            shape.path = path.copy(using: &flip)
            shape.strokeColor = index == 0 ? color : color?.copy(alpha: (color?.alpha ?? 1) * Self.trackOpacity)
        }
    }
}

nonisolated private struct WaveLine: Shape {
    let strip: WaveStrip

    func path(in rect: CGRect) -> Path { strip.main(width: rect.width) }
}

/// 静止时的子代理细轨（同 `WaveStrip` 的高度与虚线节奏）。
nonisolated private struct WaveTracks: Shape {
    let count: Int

    func path(in rect: CGRect) -> Path {
        Path { path in
            for index in 0..<count {
                let y = WaveStrip.trackY(index)
                let dash = WaveStrip.dashes[index]
                var x: CGFloat = 0
                while x < rect.width {
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: min(x + dash[0], rect.width), y: y))
                    x += dash[0] + dash[1]
                }
            }
        }
    }
}

/// 停住与歇着的平线：竖直居中；停住的右端让出末端那个点，歇着的（`full`）画满。
nonisolated private struct StoppedLine: Shape {
    var full = false

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: full ? rect.maxX : rect.maxX - 7, y: rect.midY))
        }
    }
}
