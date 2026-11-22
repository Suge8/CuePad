import SwiftUI

/// 开屏的点阵屏：App 接手那一刻，一道斜光从左上扫到右下，扫过的点亮起、之后一直缓缓流动（两层噪声往右流，同思考档那条光带），
/// 字标被扫到时闪一下金、之后留下思考档的色带。扫到之前一格不亮，与启动图那一帧（墨色、米白的字、Cue）接上。
/// 一格一个像素按时间逐帧算好，铺上去用最近邻放大；点那一层再盖一张点形的遮罩。在后台画：Mac 整窗几万格、几十帧。
nonisolated struct OpeningLight: Sendable {
    typealias RGB = SIMD3<Double>

    struct Paint: Sendable {
        let ramp: [RGB]
        let spark: RGB
        let cream: RGB
    }

    struct Frames: Sendable {
        let mark: [CGImage]
        let matrix: [CGImage]
        let dots: CGImage
    }

    /// 一格的边长（pt）：字标的一个像素，也是点阵屏的一个点位。
    static let cell: CGFloat = 7
    /// 斜光从左上扫到右下要多久。
    static let sweep = 0.9
    static let fps = 30.0
    /// 逐帧算到最晚开门（光扫完、或等天空等到 `OpeningDoor.patience`）再加门开的时长，之后停在最后一帧。
    static let span = max(sweep, OpeningDoor.patience / .seconds(1)) + OpeningDoor.reveal
    /// 点在一格里四周留的空（pt）。
    private static let gap: CGFloat = 1.4

    let grid: OpeningDoor.Grid
    let paint: Paint

    /// 启动图那一版：整个字标米白。
    static func still(_ paint: Paint) -> CGImage {
        CueWordmark.image { _ in OpeningDoor.pixel(paint.cream) }
    }

    func frames(scale: CGFloat) -> Frames {
        let times = (0...Int(Self.span * Self.fps)).map { Double($0) / Self.fps }
        let cells = (0..<grid.rows * grid.columns).map { index in
            let (row, column) = index.quotientAndRemainder(dividingBy: grid.columns)
            return Cell(SIMD2(column, row), on: grid, paint: paint)
        }
        let mark = CueWordmark.size, inMark = { (cell: SIMD2<Int>) in cell &+ grid.mark }
        return Frames(
            mark: times.map { t in
                let front = Self.front(t)
                return CueWordmark.image { at in cells[inMark(at).y * grid.columns + inMark(at).x].mark(at, of: mark, front: front, paint) }
            },
            matrix: times.map { t in
                let front = Self.front(t)
                var pixels = [OpeningDoor.Pixel](repeating: 0, count: cells.count)
                for (index, cell) in cells.enumerated() where !cell.letter {
                    pixels[index] = cell.dot(at: t, front: front, paint)
                }
                return OpeningDoor.image(pixels, size: SIMD2(grid.columns, grid.rows))
            },
            dots: dots(scale: scale))
    }

    /// 斜光此刻扫到哪：沿左上到右下的对角线量，0 在左上角、1 在右下角。
    private static func front(_ t: Double) -> Double { -0.17 + 1.19 * Double(OpeningDoor.inOut3(min(1, t / sweep))) }

    /// 一格不随时间变的那些：归不归字标、在对角线上的位置、点的颜色、抖动阈值。
    private struct Cell {
        let at: SIMD2<Int>
        /// 字标占的格：这一格归字标那一层画。
        let letter: Bool
        let u: Double
        let hue: RGB
        let threshold: Double

        init(_ at: SIMD2<Int>, on grid: OpeningDoor.Grid, paint: Paint) {
            let p = grid.center(at), size = grid.size
            self.at = at
            letter = CueWordmark.cells.contains(at &- grid.mark)
            u = Double((0.8 * p.x + 0.45 * p.y) / (0.8 * size.width + 0.45 * size.height))
            hue = OpeningLight.ramp(Double(p.x / size.width) * 0.8 + Double(p.y / size.height) * 0.3, paint)
            threshold = OpeningLight.bayer(at)
        }

        /// 离斜光多近（1 在光正中），与光扫过它多久了（0 还没到，1 早过去了）。
        private func light(_ front: Double) -> (band: Double, behind: Double) {
            (exp(-pow((u - front) / 0.09, 2)), OpeningLight.smoothstep(0.03, -0.11, u - front))
        }

        func dot(at t: Double, front: Double, _ paint: Paint) -> OpeningDoor.Pixel {
            let (band, behind) = light(front)
            guard band > 0.001 || behind > 0.001 else { return 0 }
            let x = Double(at.x), y = Double(at.y)
            let flow = OpeningLight.noise(x / 7 + t * 0.55, y / 7 - t * 0.25) * 0.65 + OpeningLight.noise(x / 2.6 - t * 0.9, y / 2.6) * 0.35
            let level = band * 1.25 + behind * (0.08 + 0.62 * pow(flow, 1.6))
            let lit = (level * 3 + threshold).rounded(.down) / 3
            let color = lit > 1 ? OpeningLight.mix(hue, paint.spark, 0.6) : OpeningLight.mix(hue * 0.9, OpeningLight.min1(hue * 1.25), lit)
            return OpeningDoor.pixel(color, alpha: min(1, 0.11 * behind + 0.85 * min(lit, 1)))
        }

        /// 字标的这一格：扫到之前米白，光正中闪金，扫过后留下思考档的色带（左到右、上亮下暗）。
        func mark(_ at: SIMD2<Int>, of size: SIMD2<Int>, front: Double, _ paint: Paint) -> OpeningDoor.Pixel {
            let (band, behind) = light(front)
            let along = Double(at.x) / Double(size.x), v = Double(at.y) / Double(size.y)
            let hue = OpeningLight.ramp(along * 0.85 + v * 0.15, paint)
            let lit = OpeningLight.mix(hue * 0.85, OpeningLight.min1(hue * 1.3), 1 - v)
            let base = OpeningLight.mix(paint.cream, lit, OpeningLight.smoothstep(0.2, 1, behind))
            return OpeningDoor.pixel(OpeningLight.mix(base, OpeningLight.mix(paint.cream, paint.spark, band), OpeningLight.smoothstep(0.35, 0.95, band)))
        }
    }

    /// 点阵屏的点：每格正中一块方点，对齐到设备像素。
    private func dots(scale: CGFloat) -> CGImage {
        let cell = Int((Self.cell * scale).rounded()), inset = Int((Self.gap * scale).rounded())
        let context = CGContext(
            data: nil, width: grid.columns * cell, height: grid.rows * cell, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                context.fill(CGRect(x: column * cell + inset, y: row * cell + inset, width: cell - 2 * inset, height: cell - 2 * inset))
            }
        }
        return context.makeImage()!
    }

    /// 8×8 有序抖动的阈值，同 Cue 页的天与思考档（按位交错算出来）。
    static func bayer(_ cell: SIMD2<Int>) -> Double {
        let x = (cell.x ^ cell.y) & 7, y = cell.y & 7
        var v = 0
        for bit in 0..<3 { v |= ((x >> bit) & 1) << (5 - 2 * bit) | ((y >> bit) & 1) << (4 - 2 * bit) }
        return (Double(v) + 0.5) / 64
    }

    private static func hash(_ x: Double, _ y: Double) -> Double {
        var a = x * 123.34, b = y * 456.21
        a -= a.rounded(.down)
        b -= b.rounded(.down)
        let d = a * (a + 45.32) + b * (b + 45.32)
        let v = (a + d) * (b + d)
        return v - v.rounded(.down)
    }

    fileprivate static func noise(_ x: Double, _ y: Double) -> Double {
        let i = x.rounded(.down), j = y.rounded(.down), fx = x - i, fy = y - j
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1)
        let bottom = a + (b - a) * ux, top = c + (d - c) * ux
        return bottom + (top - bottom) * uy
    }

    fileprivate static func ramp(_ x: Double, _ paint: Paint) -> RGB {
        let step = min(1.999, max(0, x * 2)), low = Int(step)
        return mix(paint.ramp[low], paint.ramp[low + 1], step - Double(low))
    }

    fileprivate static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    fileprivate static func min1(_ c: RGB) -> RGB { c.clamped(lowerBound: .zero, upperBound: .one) }

    fileprivate static func mix(_ a: RGB, _ b: RGB, _ k: Double) -> RGB { a + (b - a) * k }
}

extension OpeningLight.Paint {
    /// 开屏的底总是墨色，取深色那一套：思考档的色带与火花，字是深色模式的墨（米白）。
    static var launch: Self {
        let palette = Palette(dark: true), environment = EnvironmentValues()
        let rgb = { (color: Color) in OpeningDoor.rgb(color.resolve(in: environment).cgColor) }
        return Self(ramp: [palette.thinkingLow, palette.thinkingMid, palette.thinkingHigh].map(rgb), spark: rgb(palette.thinkingSpark), cream: rgb(palette.ink))
    }
}
