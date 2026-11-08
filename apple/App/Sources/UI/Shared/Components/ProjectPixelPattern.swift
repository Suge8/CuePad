import SwiftUI

/// 主题首次使用时栅格化几何蒙版，以 Bayer 决定颜料归属，再合并为每色一条静态路径。
/// 临时灰度缓冲与色号网格在生成后释放；保留的只有底色与批量路径，不保留位图。
nonisolated struct ProjectPixelPattern: Sendable {
    static let columns = 220
    static let rows = 100
    let ground: Color
    let fills: [Fill]

    struct Fill: Sendable {
        let color: Color
        let path: Path
    }

    private static let whale = Self(WhaleIllustration.artwork())
    private static let shark = Self(SharkIllustration.artwork())
    private static let jellyfish = Self(JellyfishIllustration.artwork())
    private static let turtle = Self(TurtleIllustration.artwork())
    private static let fox = Self(FoxIllustration.artwork())
    private static let cat = Self(CatIllustration.artwork())
    private static let penguin = Self(PenguinIllustration.artwork())
    private static let owl = Self(OwlIllustration.artwork())
    private static let monstera = Self(MonsteraIllustration.artwork())
    private static let cactus = Self(CactusIllustration.artwork())
    private static let mushroom = Self(MushroomIllustration.artwork())
    private static let flower = Self(FlowerIllustration.artwork())

    static func pattern(for style: ProjectCoverStyle) -> Self {
        switch style {
        case .whale: whale
        case .shark: shark
        case .jellyfish: jellyfish
        case .turtle: turtle
        case .fox: fox
        case .cat: cat
        case .penguin: penguin
        case .owl: owl
        case .monstera: monstera
        case .cactus: cactus
        case .mushroom: mushroom
        case .flower: flower
        }
    }

    private init(_ artwork: ProjectIllustration) {
        let inks = Self.sample(artwork.layers)
        var paths = Array(repeating: Path(), count: artwork.pigments.count)
        for y in 0..<Self.rows {
            var x = 0
            while x < Self.columns {
                let ink = inks[y * Self.columns + x]
                let start = x
                repeat { x += 1 } while x < Self.columns && inks[y * Self.columns + x] == ink
                if ink != 0 { paths[ink].addRect(CGRect(x: start, y: y, width: x - start, height: 1)) }
            }
        }
        let colors = Color.illustrationColors(artwork.pigments)
        ground = colors[0]
        fills = colors.indices.dropFirst().map { Fill(color: colors[$0], path: paths[$0]) }
    }

    private static func sample(_ layers: [ProjectIllustration.Layer]) -> [Int] {
        let count = columns * rows
        var inks = Array(repeating: 0, count: count)
        var mask = Array(repeating: UInt8(0), count: count)
        let thresholds = (0..<count).map { threshold(x: $0 % columns, y: $0 / columns) }
        mask.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                    bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            // 蒙版的内存行从顶部读，翻转 CGContext 的 y 轴以兑现主题的左上原点。
            context.translateBy(x: 0, y: CGFloat(rows))
            context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(false)
            for layer in layers {
                context.clear(CGRect(x: 0, y: 0, width: columns, height: rows))
                context.setFillColor(gray: 1, alpha: 1)
                context.addPath(layer.path.cgPath)
                context.drawPath(using: .eoFill)
                for index in 0..<count where bytes[index] != 0 && thresholds[index] < layer.coverage {
                    inks[index] = layer.ink
                }
            }
        }
        return inks
    }

    /// 8×8 Bayer 阈值只在首次采样时使用，所有主题共享同一顺序。
    private static func threshold(x: Int, y: Int) -> Double {
        let order = [0, 2, 3, 1]
        let low = order[(x & 1) + ((y & 1) << 1)]
        let middle = order[((x >> 1) & 1) + (((y >> 1) & 1) << 1)]
        let high = order[((x >> 2) & 1) + (((y >> 2) & 1) << 1)]
        return (Double(low * 16 + middle * 4 + high) + 0.5) / 64
    }
}
