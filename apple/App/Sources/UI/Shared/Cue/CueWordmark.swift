import SwiftUI

/// 开屏 Cue 脚下那行像素字标「CuePad」：字母是两格粗的 6×9 点阵，每格再分 3×3 个网点，
/// 按思考档的色带（钴蓝 → 紫 → 玫红）从左到右抖成网点，同 Cue 页的天、思考轨道一种质感；
/// 右下叠四层渐暗的厚度，字的上沿、左沿提亮一线；等门开时一道金光从左扫到右、右半边几颗金点明灭（金同思考最高档的火花）。
/// 一个网点画成一像素，铺上去用最近邻放大。iOS 的启动图（`LaunchStage`）是第 0 帧连着 Cue 导出的（`-CuePadLaunchArt`）：改了这里的画法要重导，不然启动屏与开屏第一帧接不上。
nonisolated enum CueWordmark {
    typealias RGB = SIMD3<Double>

    struct Paint: Sendable {
        let ramp: [RGB]
        let spark: RGB
    }

    private static let glyphs = [
        [".#####", "######", "##....", "##....", "##....", "##....", "##....", "######", ".#####"],
        ["......", "......", "......", "##..##", "##..##", "##..##", "##..##", "######", ".#####"],
        ["......", "......", "......", ".####.", "##..##", "######", "##....", "######", ".#####"],
        ["#####.", "######", "##..##", "##..##", "######", "#####.", "##....", "##....", "##...."],
        ["......", "......", "......", "#####.", "....##", ".#####", "##..##", "######", ".#####"],
        ["....##", "....##", "....##", ".#####", "######", "##..##", "##..##", "######", ".#####"],
    ]
    private static let advance = 7
    private static let split = 3
    private static let cells: Set<SIMD2<Int>> = Set(glyphs.enumerated().flatMap { letter, rows in
        rows.enumerated().flatMap { row, line in
            line.enumerated().compactMap { column, mark in mark == "#" ? SIMD2(letter * advance + column, row) : nil }
        }
    })
    /// 字面的网点数（不含厚度）。
    static let face = SIMD2((glyphs.count * advance - 1) * split, glyphs[0].count * split)
    /// 厚度一层层往右下错开的网点数，远的先画。
    private static let depth = [SIMD2(3, 4), SIMD2(2, 3), SIMD2(2, 2), SIMD2(1, 1)]
    /// 整张图的网点数：字面连右下的厚度。
    static let size = face &+ depth[0]
    /// 金光扫一趟（连空档）的秒数，等门时循环。
    static let period = 1.6 / 0.9
    private static let fps = 30.0

    private struct Dot {
        let at: SIMD2<Int>
        let lit: Bool
    }

    private static let dots: [Dot] = cells.flatMap { cell in
        (0..<split * split).map { index in
            let inner = SIMD2(index % split, index / split)
            let lit = inner.y == 0 && !cells.contains(cell &- SIMD2(0, 1)) || inner.x == 0 && !cells.contains(cell &- SIMD2(1, 0))
            return Dot(at: cell &* split &+ inner, lit: lit)
        }
    }

    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { $0 / 16 }

    /// 一个网点占几个设备像素：约 2.6pt，取整到像素才不糊（3x 8、2x 5）。
    static func dot(scale: CGFloat) -> CGFloat { (2.6 * scale).rounded() }

    static func points(_ dots: SIMD2<Int>, scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(dots.x) * dot(scale: scale) / scale, height: CGFloat(dots.y) * dot(scale: scale) / scale)
    }

    /// 等门时循环的那一趟，第 0 帧即 `image(at: 0)`。
    static func frames(_ paint: Paint) -> [CGImage] {
        (0..<Int(period * fps)).map { image(at: Double($0) / fps, paint) }
    }

    static func image(at t: Double, _ paint: Paint) -> CGImage {
        var pixels = [OpeningDoor.Pixel](repeating: 0, count: size.x * size.y)
        for (layer, offset) in depth.enumerated() {
            let dim = 0.55 + Double(depth.count - layer) * 0.06
            for dot in dots {
                let (low, high, f) = ramp(along(dot.at), paint)
                let at = dot.at &+ offset
                pixels[at.y * size.x + at.x] = OpeningDoor.pixel(mix(mix(low, high, f), .zero, dim))
            }
        }
        let band = (t * 0.9).truncatingRemainder(dividingBy: 1.6) - 0.1
        let twinkle = 2 * .pi * 2 * t / period
        for dot in dots {
            let v = along(dot.at), threshold = bayer[dot.at.y % 4 * 4 + dot.at.x % 4]
            let (low, high, f) = ramp(v, paint)
            var color = f > threshold ? high : low
            if dot.lit { color = mix(color, .one, 0.38) }
            let shine = 1 - abs(v - band) / 0.09
            if shine > threshold { color = mix(color, paint.spark, 0.85) }
            let seed = sin(Double(dot.at.x) * 12.9898 + Double(dot.at.y) * 78.233) * 43758.5453, hash = seed - seed.rounded(.down)
            if v > 0.7, hash > 0.975, sin(twinkle + hash * 60) > 0 { color = paint.spark }
            pixels[dot.at.y * size.x + dot.at.x] = OpeningDoor.pixel(color)
        }
        return OpeningDoor.image(pixels, size: size)
    }

    /// 这个网点在色带上走到哪（0 左 → 1 右，略随高度斜一点）。
    private static func along(_ at: SIMD2<Int>) -> Double {
        Double(at.x) / Double(face.x) * 0.9 + Double(at.y) / Double(face.y) * 0.1
    }

    private static func ramp(_ v: Double, _ paint: Paint) -> (RGB, RGB, Double) {
        let step = min(1.999, max(0, v * 2)), low = Int(step)
        return (paint.ramp[low], paint.ramp[low + 1], step - Double(low))
    }

    private static func mix(_ a: RGB, _ b: RGB, _ k: Double) -> RGB { a + (b - a) * k }
}

extension CueWordmark.Paint {
    /// 启动那一幕的底总是墨色，取思考档深色那一套。
    static var launch: Self {
        let palette = Palette(dark: true), environment = EnvironmentValues()
        let rgb = { (color: Color) in OpeningDoor.rgb(color.resolve(in: environment).cgColor) }
        return Self(ramp: [palette.thinkingLow, palette.thinkingMid, palette.thinkingHigh].map(rgb), spark: rgb(palette.thinkingSpark))
    }
}
