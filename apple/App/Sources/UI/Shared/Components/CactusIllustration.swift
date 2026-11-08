import SwiftUI

/// 沙地里的柱状仙人掌：左低右高的分枝、顺着体积弯曲的肋纹，顶端一朵陶橙小花。
nonisolated enum CactusIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xE5D8BA, 0x345D50, 0x668D76, 0xAEC0A0, 0xBF7955, 0xF4E8CF], layers: [
            .init(path: sand, ink: 4, coverage: 0.16),
            .init(path: Path(ellipseIn: CGRect(x: 60, y: 85, width: 103, height: 9)), ink: 1, coverage: 0.22),
            .init(path: body, ink: 2),
            .init(path: shade, ink: 1),
            .init(path: softShade, ink: 1, coverage: 0.35),
            .init(path: light, ink: 3, coverage: 0.7),
            .init(path: ribs.strokedPath(StrokeStyle(lineWidth: 1.15, lineCap: .round)), ink: 3),
            .init(path: darkRibs.strokedPath(StrokeStyle(lineWidth: 0.8, lineCap: .round)), ink: 1, coverage: 0.65),
            .init(path: spines.strokedPath(StrokeStyle(lineWidth: 0.85, lineCap: .round)), ink: 5),
            .init(path: blossom, ink: 4),
            .init(path: blossomLight, ink: 5, coverage: 0.65),
            .init(path: Path(ellipseIn: CGRect(x: 96, y: 17, width: 5, height: 3)), ink: 1),
            .init(path: stones, ink: 4),
            .init(path: stoneLight, ink: 5, coverage: 0.65)
        ])
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 90, y: 88))
            p.addLine(to: .init(x: 89, y: 67))
            p.addCurve(to: .init(x: 60, y: 49), control1: .init(x: 67, y: 69), control2: .init(x: 59, y: 62))
            p.addLine(to: .init(x: 60, y: 39))
            p.addCurve(to: .init(x: 74, y: 39), control1: .init(x: 60, y: 28), control2: .init(x: 74, y: 30))
            p.addLine(to: .init(x: 74, y: 49))
            p.addQuadCurve(to: .init(x: 89, y: 53), control: .init(x: 75, y: 56))
            p.addLine(to: .init(x: 89, y: 28))
            p.addCurve(to: .init(x: 113, y: 27), control1: .init(x: 88, y: 10), control2: .init(x: 114, y: 10))
            p.addLine(to: .init(x: 114, y: 45))
            p.addQuadCurve(to: .init(x: 133, y: 33), control: .init(x: 133, y: 47))
            p.addLine(to: .init(x: 133, y: 23))
            p.addCurve(to: .init(x: 147, y: 23), control1: .init(x: 133, y: 13), control2: .init(x: 147, y: 14))
            p.addLine(to: .init(x: 147, y: 37))
            p.addCurve(to: .init(x: 114, y: 60), control1: .init(x: 147, y: 54), control2: .init(x: 132, y: 61))
            p.addLine(to: .init(x: 115, y: 88))
            p.addQuadCurve(to: .init(x: 90, y: 88), control: .init(x: 101, y: 92)); p.closeSubpath()
        }
    }

    private static var shade: Path {
        Path { p in
            p.move(to: .init(x: 108, y: 20))
            p.addQuadCurve(to: .init(x: 113, y: 28), control: .init(x: 114, y: 22))
            p.addLine(to: .init(x: 114, y: 45))
            p.addQuadCurve(to: .init(x: 140, y: 33), control: .init(x: 140, y: 48))
            p.addLine(to: .init(x: 141, y: 19))
            p.addQuadCurve(to: .init(x: 147, y: 24), control: .init(x: 147, y: 17))
            p.addLine(to: .init(x: 147, y: 37))
            p.addCurve(to: .init(x: 114, y: 60), control1: .init(x: 147, y: 54), control2: .init(x: 132, y: 61))
            p.addLine(to: .init(x: 115, y: 88)); p.addLine(to: .init(x: 106, y: 89))
            p.addQuadCurve(to: .init(x: 108, y: 20), control: .init(x: 110, y: 54)); p.closeSubpath()
            p.move(to: .init(x: 68, y: 35))
            p.addQuadCurve(to: .init(x: 74, y: 39), control: .init(x: 74, y: 32))
            p.addLine(to: .init(x: 74, y: 49))
            p.addQuadCurve(to: .init(x: 89, y: 53), control: .init(x: 75, y: 56))
            p.addLine(to: .init(x: 89, y: 59))
            p.addQuadCurve(to: .init(x: 68, y: 49), control: .init(x: 67, y: 60)); p.closeSubpath()
        }
    }

    private static var softShade: Path {
        Path { p in
            p.move(to: .init(x: 102, y: 22)); p.addLine(to: .init(x: 108, y: 20))
            p.addQuadCurve(to: .init(x: 106, y: 89), control: .init(x: 110, y: 54))
            p.addLine(to: .init(x: 100, y: 89))
            p.addQuadCurve(to: .init(x: 102, y: 22), control: .init(x: 105, y: 53)); p.closeSubpath()
        }
    }

    private static var light: Path {
        Path { p in
            p.move(to: .init(x: 99, y: 19))
            p.addQuadCurve(to: .init(x: 92, y: 29), control: .init(x: 91, y: 19))
            p.addLine(to: .init(x: 93, y: 87)); p.addLine(to: .init(x: 99, y: 88))
            p.addQuadCurve(to: .init(x: 99, y: 19), control: .init(x: 96, y: 48)); p.closeSubpath()
            p.move(to: .init(x: 64, y: 35)); p.addQuadCurve(to: .init(x: 64, y: 50), control: .init(x: 61, y: 43))
            p.addQuadCurve(to: .init(x: 86, y: 63), control: .init(x: 66, y: 63))
            p.addQuadCurve(to: .init(x: 67, y: 50), control: .init(x: 69, y: 58))
            p.addLine(to: .init(x: 67, y: 35)); p.closeSubpath()
            p.move(to: .init(x: 136, y: 22)); p.addLine(to: .init(x: 136, y: 34))
            p.addQuadCurve(to: .init(x: 119, y: 49), control: .init(x: 135, y: 46))
            p.addQuadCurve(to: .init(x: 139, y: 34), control: .init(x: 141, y: 48))
            p.addLine(to: .init(x: 139, y: 21)); p.closeSubpath()
        }
    }

    private static var ribs: Path {
        Path { p in
            p.move(to: .init(x: 101, y: 20)); p.addCurve(to: .init(x: 102, y: 86), control1: .init(x: 98, y: 39), control2: .init(x: 102, y: 64))
            p.move(to: .init(x: 65, y: 36)); p.addLine(to: .init(x: 65, y: 49))
            p.addQuadCurve(to: .init(x: 87, y: 63), control: .init(x: 65, y: 63))
            p.move(to: .init(x: 138, y: 21)); p.addLine(to: .init(x: 138, y: 34))
            p.addQuadCurve(to: .init(x: 117, y: 52), control: .init(x: 139, y: 50))
        }
    }

    private static var darkRibs: Path {
        Path { p in
            p.move(to: .init(x: 95, y: 23)); p.addQuadCurve(to: .init(x: 95, y: 84), control: .init(x: 91, y: 45))
            p.move(to: .init(x: 104, y: 24)); p.addQuadCurve(to: .init(x: 105, y: 84), control: .init(x: 107, y: 49))
        }
    }

    private static var spines: Path {
        Path { p in
            for point in [CGPoint(x: 95, y: 31), .init(x: 95, y: 47), .init(x: 96, y: 65), .init(x: 102, y: 77), .init(x: 65, y: 43), .init(x: 76, y: 61), .init(x: 138, y: 29), .init(x: 129, y: 48)] {
                p.move(to: .init(x: point.x - 2, y: point.y - 1.5)); p.addLine(to: point)
                p.addLine(to: .init(x: point.x + 1.8, y: point.y - 2))
            }
            p.move(to: .init(x: 89, y: 37)); p.addLine(to: .init(x: 86, y: 35))
            p.move(to: .init(x: 114, y: 72)); p.addLine(to: .init(x: 117, y: 70))
            p.move(to: .init(x: 146, y: 32)); p.addLine(to: .init(x: 150, y: 30))
        }
    }

    private static var blossom: Path {
        Path { p in
            p.move(to: .init(x: 96, y: 19))
            p.addQuadCurve(to: .init(x: 87, y: 12), control: .init(x: 88, y: 20))
            p.addQuadCurve(to: .init(x: 95, y: 13), control: .init(x: 90, y: 10))
            p.addQuadCurve(to: .init(x: 96, y: 6), control: .init(x: 92, y: 8))
            p.addQuadCurve(to: .init(x: 100, y: 12), control: .init(x: 100, y: 7))
            p.addQuadCurve(to: .init(x: 106, y: 8), control: .init(x: 101, y: 7))
            p.addQuadCurve(to: .init(x: 104, y: 15), control: .init(x: 108, y: 12))
            p.addQuadCurve(to: .init(x: 108, y: 15), control: .init(x: 109, y: 12))
            p.addQuadCurve(to: .init(x: 96, y: 19), control: .init(x: 105, y: 23)); p.closeSubpath()
        }
    }

    private static var blossomLight: Path {
        Path { p in
            p.move(to: .init(x: 90, y: 13)); p.addQuadCurve(to: .init(x: 98, y: 18), control: .init(x: 94, y: 13))
            p.addLine(to: .init(x: 97, y: 9)); p.addLine(to: .init(x: 101, y: 16))
            p.addLine(to: .init(x: 105, y: 11)); p.addLine(to: .init(x: 102, y: 19)); p.closeSubpath()
        }
    }

    private static var sand: Path {
        Path { p in
            p.move(to: .init(x: 33, y: 88)); p.addQuadCurve(to: .init(x: 173, y: 88), control: .init(x: 105, y: 78))
            p.addQuadCurve(to: .init(x: 192, y: 97), control: .init(x: 188, y: 89))
            p.addQuadCurve(to: .init(x: 33, y: 88), control: .init(x: 87, y: 102)); p.closeSubpath()
        }
    }

    private static var stones: Path {
        Path { p in
            p.move(to: .init(x: 137, y: 86)); p.addLine(to: .init(x: 144, y: 79))
            p.addQuadCurve(to: .init(x: 155, y: 87), control: .init(x: 152, y: 78))
            p.addQuadCurve(to: .init(x: 137, y: 86), control: .init(x: 148, y: 90)); p.closeSubpath()
            p.move(to: .init(x: 53, y: 90)); p.addQuadCurve(to: .init(x: 63, y: 90), control: .init(x: 58, y: 80))
            p.closeSubpath()
        }
    }

    private static var stoneLight: Path {
        Path { p in
            p.move(to: .init(x: 139, y: 85)); p.addLine(to: .init(x: 145, y: 80))
            p.addLine(to: .init(x: 149, y: 82)); p.addLine(to: .init(x: 145, y: 86)); p.closeSubpath()
        }
    }
}
