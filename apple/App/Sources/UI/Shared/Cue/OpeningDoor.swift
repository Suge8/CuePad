import QuartzCore

/// 开门的时间线：墨色从 Cue 身上碎成方格、由近及远散开露出 App，整个窗口从近处退回原位；
/// Cue 先蹲一下，跳着飞回它住的地方。摆法同启动屏（`Stage`），时间按开门起的秒数。
struct OpeningDoor {
    /// 启动那一幕：字标（`CueWordmark`）两行，Cue 站在「ue」顶上，整组在窗口正中，同 iOS 启动图（`LaunchStage`，系统把它摆在屏幕正中）。
    struct Stage {
        let cue: CGRect
        let mark: CGRect
        let grid: Grid
        /// Cue 的中心，从窗口左上起量：墨色从这里散开。
        let heart: CGPoint

        init(in bounds: CGRect, scale: CGFloat, up: CGFloat) {
            let cell = OpeningLight.cell, cue = OpeningDoor.cue
            let mark = CGSize(width: CGFloat(CueWordmark.size.x) * cell, height: CGFloat(CueWordmark.size.y) * cell)
            let feet = CGFloat(CueWordmark.perch.y) * cell + Self.sink, total = cue.height - feet + mark.height
            let snap = { (v: CGFloat) in (v * scale).rounded() / scale }
            let markAt = CGPoint(x: snap((bounds.width - mark.width) / 2), y: snap((bounds.height - total) / 2 + cue.height - feet))
            let cueAt = CGPoint(x: markAt.x + CGFloat(CueWordmark.perch.x) * cell - cue.width / 2, y: markAt.y + feet - cue.height)
            let screen = Screen(bounds: bounds, up: up)
            self.mark = screen.rect(markAt, mark)
            self.cue = screen.rect(cueAt, cue)
            grid = Grid(screen, mark: markAt)
            heart = CGPoint(x: cueAt.x + cue.width / 2, y: cueAt.y + cue.height / 2)
        }

        /// Cue 的脚陷进字顶多少：站在上面，不是浮在上面。
        private static let sink: CGFloat = 3
    }

    /// 窗口里从左上起量的位置换成这层的坐标（Mac 的层 y 朝上）。
    nonisolated struct Screen: Sendable {
        let bounds: CGRect
        let up: CGFloat

        func rect(_ at: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: bounds.minX + at.x, y: up < 0 ? bounds.minY + at.y : bounds.maxY - at.y - size.height, width: size.width, height: size.height)
        }
    }

    /// 开屏整张网：与字标的格对齐，铺满窗口，也盖住整个字标（字标尺寸固定，小窗、横屏的手机里它伸出窗外）。点阵屏、字标、碎开的墨色都在这张网上。
    nonisolated struct Grid: Sendable {
        /// 第一格的左上角，从窗口左上起量。
        let origin: CGPoint
        let columns: Int
        let rows: Int
        /// 字标左上那一格。
        let mark: SIMD2<Int>
        let size: CGSize
        let frame: CGRect

        init(_ screen: Screen, mark at: CGPoint) {
            let cell = OpeningLight.cell, end = CGFloat(CueWordmark.size.x) * cell, foot = CGFloat(CueWordmark.size.y) * cell
            let before = max(0, Int((at.x / cell).rounded(.up))), above = max(0, Int((at.y / cell).rounded(.up)))
            origin = CGPoint(x: at.x - CGFloat(before) * cell, y: at.y - CGFloat(above) * cell)
            columns = Int(((max(screen.bounds.width, at.x + end) - origin.x) / cell).rounded(.up))
            rows = Int(((max(screen.bounds.height, at.y + foot) - origin.y) / cell).rounded(.up))
            mark = SIMD2(before, above)
            size = screen.bounds.size
            frame = screen.rect(origin, CGSize(width: CGFloat(columns) * cell, height: CGFloat(rows) * cell))
        }

        func center(_ cell: SIMD2<Int>) -> CGPoint {
            CGPoint(x: origin.x + (CGFloat(cell.x) + 0.5) * OpeningLight.cell, y: origin.y + (CGFloat(cell.y) + 0.5) * OpeningLight.cell)
        }
    }

    struct Landing {
        let spot: CueSpot?
        let frame: CGRect
    }

    struct Frame {
        let cue: CGRect
        let zoom: CGFloat
    }

    /// 启动屏上那个 Cue 的大小。
    static let cue = CGSize(width: 150, height: 142.5)
    /// 天空等不到就不等了（Cue 栏收着时它可能不画）。
    nonisolated static let patience = Duration.seconds(1)
    static let crouch = 0.15
    static let flight = 1.08
    static let duration = crouch + flight
    /// 飞到这一成之前是跳起的姿势，之后换回站姿落地。
    static let airborne = 0.8
    /// 墨色散尽要多久。
    nonisolated static let reveal = 1.17
    nonisolated private static let fps = 60.0
    /// 格子按离 Cue 的远近排先后，再按有序抖动错开一点：前沿是一圈抖动的格子，同 Cue 页天空的像素，不是一条光滑的圆边。
    nonisolated private static let spread = 0.12
    /// 前沿最外这一圈格子先变成签名色再散。
    nonisolated private static let edge = 0.035
    private static let zoom: CGFloat = 0.05
    private static let lift: CGFloat = 70

    let bounds: CGRect
    let start: CGRect
    let up: CGFloat
    let landing: Landing?

    var frames: [Frame] { (0...Int(Self.duration * Self.fps)).map { at(Double($0) / Self.fps) } }

    /// 第 `t` 秒：蹲下（宽一点、矮一点，脚不动）、再沿弧线飞到落点，同时窗口从近处退回原位。
    func at(_ t: Double) -> Frame {
        let zoom = 1 + Self.zoom * (1 - Self.out3(min(1, t / Self.duration)))
        guard t >= Self.crouch else {
            let squash = CGFloat(sin(.pi * t / Self.crouch)) * 0.08
            let size = CGSize(width: start.width * (1 + squash * 0.6), height: start.height * (1 - squash))
            let foot = up < 0 ? start.maxY : start.minY
            return Frame(cue: CGRect(x: start.midX - size.width / 2, y: up < 0 ? foot - size.height : foot, width: size.width, height: size.height), zoom: zoom)
        }
        let e = Self.inOut3(min(1, (t - Self.crouch) / Self.flight))
        let to = landing?.frame ?? start
        var cue = CGRect(
            x: start.minX + (to.minX - start.minX) * e, y: start.minY + (to.minY - start.minY) * e,
            width: start.width + (to.width - start.width) * e, height: start.height + (to.height - start.height) * e)
        let lift = landing.map { min(Self.lift, 0.3 * hypot($0.frame.midX - start.midX, $0.frame.midY - start.midY)) } ?? 0
        cue.origin.y += up * CGFloat(sin(.pi * Double(e))) * lift
        return Frame(cue: cue, zoom: zoom)
    }

    /// 墨色从 `heart`（Cue 身上）散开的逐帧图：一格一个像素，铺到 `grid` 上用最近邻放大。门开前在后台画（Mac 整窗上万格、几十帧）。
    nonisolated static func veil(on grid: Grid, from heart: CGPoint, ink: Pixel, edge: Pixel) -> [CGImage] {
        let corners = [CGPoint.zero, CGPoint(x: grid.size.width, y: 0), CGPoint(x: 0, y: grid.size.height), CGPoint(x: grid.size.width, y: grid.size.height)]
        let far = Double(corners.map { hypot($0.x - heart.x, $0.y - heart.y) }.max()! + 2 * OpeningLight.cell)
        let threshold = (0..<grid.rows * grid.columns).map { index in
            let (row, column) = index.quotientAndRemainder(dividingBy: grid.columns), at = grid.center(SIMD2(column, row))
            return Double(hypot(at.x - heart.x, at.y - heart.y)) / far * (1 - spread) + OpeningLight.bayer(SIMD2(column, row)) * spread
        }
        return (0...Int(reveal * fps)).map { frame in
            let front = Double(inOut3(Double(frame) / fps / reveal)) * 1.22 - 0.04
            var pixels = [Pixel](repeating: 0, count: grid.rows * grid.columns)
            for (index, level) in threshold.enumerated() where front < level {
                pixels[index] = level - front < Self.edge ? edge : ink
            }
            return image(pixels, size: SIMD2(grid.columns, grid.rows))
        }
    }

    /// 一格的颜色，按内存里的 RGBA 次序装进一个数；0 是透明。
    typealias Pixel = UInt32

    nonisolated static func rgb(_ color: CGColor) -> OpeningLight.RGB {
        let rgba = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
        return OpeningLight.RGB(rgba[0], rgba[1], rgba[2])
    }

    /// 透明度先乘进颜色（图是预乘的）。
    nonisolated static func pixel(_ rgb: OpeningLight.RGB, alpha: Double = 1) -> Pixel {
        let byte = (rgb.clamped(lowerBound: .zero, upperBound: .one) * alpha * 255).rounded(.toNearestOrAwayFromZero), a = Pixel((alpha * 255).rounded())
        return (Pixel(byte.x) | Pixel(byte.y) << 8 | Pixel(byte.z) << 16 | a << 24).littleEndian
    }

    nonisolated static func image(_ pixels: [Pixel], size: SIMD2<Int>) -> CGImage {
        CGImage(
            width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func out3(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - t, 3)) }

    nonisolated static func inOut3(_ t: Double) -> CGFloat { CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2) }
}
