import QuartzCore

/// 开门的时间线：墨色从 Cue 身上碎成方格、由近及远散开露出 App，整个窗口从近处退回原位；
/// Cue 先蹲一下，跳着飞回它住的地方。摆法同启动屏（`Stage`），时间按开门起的秒数。
struct OpeningDoor {
    /// 启动那一幕：Cue 在上、字标（`CueWordmark`）在下，整组在窗口正中，同 iOS 启动图（`LaunchStage`，系统把它摆在屏幕正中）。
    struct Stage {
        let cue: CGRect
        /// 字标整张图（连右下的厚度）；字面左右居中。
        let mark: CGRect

        init(in bounds: CGRect, scale: CGFloat, up: CGFloat) {
            let face = CueWordmark.points(CueWordmark.face, scale: scale), image = CueWordmark.points(CueWordmark.size, scale: scale)
            let total = OpeningDoor.cue.height + Self.gap + face.height
            func top(_ offset: CGFloat, height: CGFloat) -> CGFloat { up < 0 ? bounds.midY + offset : bounds.midY - offset - height }
            cue = CGRect(x: bounds.midX - OpeningDoor.cue.width / 2, y: top(-total / 2, height: OpeningDoor.cue.height), width: OpeningDoor.cue.width, height: OpeningDoor.cue.height)
            let markTop = -total / 2 + OpeningDoor.cue.height + Self.gap
            mark = CGRect(x: bounds.midX - face.width / 2, y: up < 0 ? bounds.midY + markTop : bounds.midY - markTop - image.height, width: image.width, height: image.height)
        }

        /// Cue 脚下到字面顶的空：Cue 连字标是一个标志，比例定死，不随平台的间距档变（iOS 的启动图是同一张图）。
        private static let gap: CGFloat = 34
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
    /// 墨色至少停这么久：iOS 的图标还在放大成启动屏，Mac 的窗口刚出来，先看清是 Cue 再开门。
    static let dwell = Duration.milliseconds(350)
    /// 天空等不到就不等了（Cue 栏收着时它可能不画）。
    static let patience = Duration.seconds(1)
    static let crouch = 0.1
    static let flight = 0.72
    static let duration = crouch + flight
    /// 飞到这一成之前是跳起的姿势，之后换回站姿落地。
    static let airborne = 0.8
    /// 墨色散尽要多久。
    nonisolated static let reveal = 0.78
    nonisolated private static let fps = 60.0
    /// 墨色碎成的方格边长（pt）。
    nonisolated private static let cell: CGFloat = 11
    /// 格子按离 Cue 的远近排先后，再按 4×4 有序抖动错开一点：前沿是一圈抖动的格子，同 Cue 页天空的像素，不是一条光滑的圆边。
    nonisolated private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { $0 / 16 }
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

    /// 墨色那一层盖住的范围：整格铺满窗口，多出的半格伸到窗外。
    nonisolated static func grid(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX, y: bounds.minY,
            width: (bounds.width / cell).rounded(.up) * cell, height: (bounds.height / cell).rounded(.up) * cell)
    }

    /// 墨色从 `center`（Cue 身上）散开的逐帧图：一格一个像素，铺到 `grid` 上用最近邻放大。门开前在后台画好（Mac 整窗上万格、几十帧）。
    nonisolated static func veil(in bounds: CGRect, from center: CGPoint, up: CGFloat, ink: Pixel, edge: Pixel) -> [CGImage] {
        let grid = grid(in: bounds), columns = Int(grid.width / cell), rows = Int(grid.height / cell)
        let origin = CGPoint(x: center.x - grid.minX, y: up < 0 ? center.y - grid.minY : grid.maxY - center.y)
        let far = Double([bounds.minX, bounds.maxX].flatMap { x in [bounds.minY, bounds.maxY].map { hypot(x - center.x, $0 - center.y) } }.max()! + 2 * cell)
        let threshold = (0..<rows * columns).map { index in
            let (row, column) = index.quotientAndRemainder(dividingBy: columns)
            let x = (CGFloat(column) + 0.5) * cell - origin.x, y = (CGFloat(row) + 0.5) * cell - origin.y
            return Double(hypot(x, y)) / far * (1 - spread) + bayer[row % 4 * 4 + column % 4] * spread
        }
        return (0...Int(reveal * fps)).map { frame in
            let front = Double(inOut3(Double(frame) / fps / reveal)) * 1.22 - 0.04
            var pixels = [Pixel](repeating: 0, count: rows * columns)
            for (index, level) in threshold.enumerated() where front < level {
                pixels[index] = level - front < Self.edge ? edge : ink
            }
            return image(pixels, size: SIMD2(columns, rows))
        }
    }

    /// 一格的颜色（不透明），按内存里的 RGBA 次序装进一个数；0 是透明。
    typealias Pixel = UInt32

    nonisolated static func rgb(_ color: CGColor) -> CueWordmark.RGB {
        let rgba = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
        return CueWordmark.RGB(rgba[0], rgba[1], rgba[2])
    }

    nonisolated static func pixel(_ rgb: CueWordmark.RGB) -> Pixel {
        let byte = (rgb.clamped(lowerBound: .zero, upperBound: .one) * 255).rounded(.toNearestOrAwayFromZero)
        return (Pixel(byte.x) | Pixel(byte.y) << 8 | Pixel(byte.z) << 16 | 0xFF << 24).littleEndian
    }

    nonisolated static func image(_ pixels: [Pixel], size: SIMD2<Int>) -> CGImage {
        CGImage(
            width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func out3(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - t, 3)) }

    nonisolated private static func inOut3(_ t: Double) -> CGFloat { CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2) }
}
