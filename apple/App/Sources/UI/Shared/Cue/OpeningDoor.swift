import CoreGraphics

/// 开门的时间线：尺寸都按启动屏上那个 Cue 量（环在它腰上），时间都按门开的进度 `t`（0…1）。
struct OpeningDoor {
    struct Landing {
        let spot: CueSpot?
        let frame: CGRect
        let lift: CGFloat
    }

    struct Frame {
        let hole: CGRect
        let ring: CGRect
        let tube: CGFloat
        let zoom: CGFloat
        let cue: CGRect
        /// 门里透出来的光：门刚开时最亮，开到七成散尽。
        let light: Double
    }

    /// 启动屏上那个 Cue 的大小，同 `LaunchCue` 图（@3x 450 像素宽）。
    static let cue = CGSize(width: 150, height: 142.5)
    static let duration = 1.15
    /// 墨色至少停这么久：iOS 的图标还在放大成启动屏，Mac 的窗口刚出来，先看清是 Cue 再开门。
    static let dwell = Duration.milliseconds(350)
    /// 天空等不到就不等了（Cue 栏收着时它可能不画）。
    static let patience = Duration.seconds(1)
    static let grains = [5, 3, 2, 1]
    private static let thresholds = [0.2, 0.4, 0.62]
    private static let samples = 72
    private static let ringAt = (y: 0.6, rx: 0.43, ry: 0.13, tube: 0.075)
    private static let finalTube: CGFloat = 48
    private static let reach: CGFloat = 110
    private static let zoom: CGFloat = 0.26

    let bounds: CGRect
    let up: CGFloat
    let landing: Landing?

    static func start(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - cue.width / 2, y: bounds.midY - cue.height / 2, width: cue.width, height: cue.height)
    }

    var start: CGRect { Self.start(in: bounds) }

    var center: CGPoint {
        CGPoint(x: start.midX, y: start.midY - up * (Self.ringAt.y - 0.5) * start.height)
    }

    /// 门开到 `thresholds` 那几成的时刻（秒）：天空细一档。
    var steps: [Double] {
        Self.thresholds.map { threshold in
            let t = (0...Self.samples).map { Double($0) / Double(Self.samples) }.first { Self.open($0) >= threshold } ?? 1
            return t * Self.duration
        }
    }

    var frames: [Frame] { (0...Self.samples).map { at(Double($0) / Double(Self.samples)) } }

    func at(_ t: Double) -> Frame {
        let width = start.width, e = CGFloat(Self.open(t))
        let far = hypot(max(center.x - bounds.minX, bounds.maxX - center.x), max(center.y - bounds.minY, bounds.maxY - center.y)) + Self.reach
        let rx0 = width * Self.ringAt.rx, ry0 = width * Self.ringAt.ry, tube0 = width * Self.ringAt.tube
        let rx = rx0 + (far - rx0) * e
        let ry = ry0 + (rx - ry0) * Self.out3(min(1, t / 0.5))
        let tube = tube0 + (Self.finalTube - tube0) * Self.out3(min(1, t / 0.7))
        let ix = max(0, rx - tube / 2 + 1), iy = max(0, ry - tube / 2 + 1)
        let f = Self.inOut3(min(1, max(0, (t - 0.16) / 0.78)))
        let to = landing?.frame ?? start
        var cue = CGRect(
            x: start.minX + (to.minX - start.minX) * f, y: start.minY + (to.minY - start.minY) * f,
            width: start.width + (to.width - start.width) * f, height: start.height + (to.height - start.height) * f)
        cue.origin.y += up * sin(.pi * f) * (landing?.lift ?? 0)
        return Frame(
            hole: CGRect(x: center.x - ix, y: center.y - iy, width: 2 * ix, height: 2 * iy),
            ring: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry),
            tube: tube, zoom: 1 + Self.zoom * (1 - e), cue: cue, light: Double(1 - Self.inOut3(min(1, max(0, (Double(e) - 0.15) / 0.55)))))
    }

    /// 门开的快慢：起手慢、中段猛地撑开、收尾很长（cubic-bezier(.66, 0, .14, 1)）。
    private static func open(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.66, 0.0, 0.14, 1.0)
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<26 {
            u = (lo + hi) / 2
            let x = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            if x < t { lo = u } else { hi = u }
        }
        return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }

    private static func out3(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - t, 3)) }

    private static func inOut3(_ t: Double) -> CGFloat { CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2) }
}
