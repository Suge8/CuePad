import SwiftUI

/// 蓝天下偏左的一朵向日葵：不等长的金色舌状花围住焦褐花盘，弯茎向右下延伸，两片心形叶承接重量。
nonisolated enum FlowerIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xC8E4EA, 0x496E59, 0x4F382D, 0xD38C32, 0xF1C64F, 0xFFF0AB], layers: [
            .init(path: stem.strokedPath(StrokeStyle(lineWidth: 3.4, lineCap: .round)), ink: 1),
            .init(path: leaves, ink: 1),
            .init(path: leafLight, ink: 4, coverage: 0.22),
            .init(path: leafShade, ink: 2, coverage: 0.32),
            .init(path: veins.strokedPath(StrokeStyle(lineWidth: 0.85)), ink: 5, coverage: 0.65),
            .init(path: backPetals, ink: 3),
            .init(path: frontPetals, ink: 4),
            .init(path: petalLight, ink: 5, coverage: 0.65),
            .init(path: petalFolds.strokedPath(StrokeStyle(lineWidth: 0.9, lineCap: .round)), ink: 3),
            .init(path: disk, ink: 2),
            .init(path: diskEdge, ink: 3, coverage: 0.65),
            .init(path: diskLight, ink: 3, coverage: 0.32),
            .init(path: seeds.strokedPath(StrokeStyle(lineWidth: 1.05, lineCap: .round)), ink: 5, coverage: 0.6)
        ])
    }

    private static var stem: Path {
        Path { p in
            p.move(to: .init(x: 88, y: 48))
            p.addCurve(to: .init(x: 137, y: 101), control1: .init(x: 98, y: 65), control2: .init(x: 124, y: 73))
            p.move(to: .init(x: 119, y: 80)); p.addQuadCurve(to: .init(x: 138, y: 70), control: .init(x: 129, y: 80))
            p.move(to: .init(x: 122, y: 84)); p.addQuadCurve(to: .init(x: 105, y: 83), control: .init(x: 115, y: 87))
        }
    }

    private static var leaves: Path {
        Path { p in
            p.move(to: .init(x: 131, y: 77))
            p.addCurve(to: .init(x: 140, y: 60), control1: .init(x: 125, y: 66), control2: .init(x: 133, y: 57))
            p.addCurve(to: .init(x: 171, y: 55), control1: .init(x: 151, y: 64), control2: .init(x: 161, y: 60))
            p.addLine(to: .init(x: 165, y: 64)); p.addLine(to: .init(x: 165, y: 68))
            p.addCurve(to: .init(x: 141, y: 82), control1: .init(x: 159, y: 81), control2: .init(x: 150, y: 85))
            p.addQuadCurve(to: .init(x: 131, y: 77), control: .init(x: 133, y: 83)); p.closeSubpath()
            p.move(to: .init(x: 111, y: 83))
            p.addCurve(to: .init(x: 97, y: 70), control1: .init(x: 118, y: 73), control2: .init(x: 104, y: 66))
            p.addCurve(to: .init(x: 72, y: 67), control1: .init(x: 87, y: 73), control2: .init(x: 80, y: 72))
            p.addLine(to: .init(x: 76, y: 76)); p.addLine(to: .init(x: 76, y: 79))
            p.addCurve(to: .init(x: 99, y: 92), control1: .init(x: 82, y: 91), control2: .init(x: 91, y: 94))
            p.addQuadCurve(to: .init(x: 111, y: 83), control: .init(x: 111, y: 94)); p.closeSubpath()
        }
    }

    private static var leafLight: Path {
        Path { p in
            p.move(to: .init(x: 131, y: 76))
            p.addCurve(to: .init(x: 140, y: 61), control1: .init(x: 127, y: 67), control2: .init(x: 134, y: 59))
            p.addQuadCurve(to: .init(x: 168, y: 57), control: .init(x: 155, y: 65))
            p.addQuadCurve(to: .init(x: 131, y: 76), control: .init(x: 150, y: 72)); p.closeSubpath()
            p.move(to: .init(x: 109, y: 82))
            p.addQuadCurve(to: .init(x: 97, y: 72), control: .init(x: 114, y: 69))
            p.addQuadCurve(to: .init(x: 76, y: 71), control: .init(x: 86, y: 75))
            p.addQuadCurve(to: .init(x: 109, y: 82), control: .init(x: 92, y: 82)); p.closeSubpath()
        }
    }

    private static var leafShade: Path {
        Path { p in
            p.move(to: .init(x: 134, y: 77)); p.addQuadCurve(to: .init(x: 159, y: 67), control: .init(x: 146, y: 76))
            p.addQuadCurve(to: .init(x: 141, y: 82), control: .init(x: 155, y: 83))
            p.addQuadCurve(to: .init(x: 134, y: 77), control: .init(x: 136, y: 82)); p.closeSubpath()
            p.move(to: .init(x: 81, y: 79)); p.addQuadCurve(to: .init(x: 110, y: 84), control: .init(x: 98, y: 84))
            p.addQuadCurve(to: .init(x: 99, y: 92), control: .init(x: 109, y: 94))
            p.addQuadCurve(to: .init(x: 81, y: 79), control: .init(x: 87, y: 93)); p.closeSubpath()
        }
    }

    private static var veins: Path {
        Path { p in
            p.move(to: .init(x: 131, y: 78)); p.addQuadCurve(to: .init(x: 165, y: 60), control: .init(x: 148, y: 75))
            p.move(to: .init(x: 143, y: 73)); p.addLine(to: .init(x: 140, y: 65))
            p.move(to: .init(x: 144, y: 74)); p.addLine(to: .init(x: 153, y: 77))
            p.move(to: .init(x: 152, y: 68)); p.addLine(to: .init(x: 152, y: 65))
            p.move(to: .init(x: 111, y: 84)); p.addQuadCurve(to: .init(x: 79, y: 74), control: .init(x: 96, y: 84))
            p.move(to: .init(x: 99, y: 82)); p.addLine(to: .init(x: 101, y: 75))
            p.move(to: .init(x: 96, y: 82)); p.addLine(to: .init(x: 91, y: 88))
        }
    }

    private static var backPetals: Path {
        Path { p in
            p.move(to: .init(x: 70, y: 25))
            p.addQuadCurve(to: .init(x: 58, y: 10), control: .init(x: 57, y: 23))
            p.addQuadCurve(to: .init(x: 77, y: 18), control: .init(x: 72, y: 9))
            p.addQuadCurve(to: .init(x: 80, y: 3), control: .init(x: 72, y: 6))
            p.addQuadCurve(to: .init(x: 88, y: 17), control: .init(x: 90, y: 8))
            p.addQuadCurve(to: .init(x: 103, y: 5), control: .init(x: 94, y: 4))
            p.addQuadCurve(to: .init(x: 102, y: 22), control: .init(x: 109, y: 15))
            p.addQuadCurve(to: .init(x: 121, y: 15), control: .init(x: 111, y: 12))
            p.addQuadCurve(to: .init(x: 108, y: 31), control: .init(x: 121, y: 28))
            p.addQuadCurve(to: .init(x: 130, y: 35), control: .init(x: 122, y: 28))
            p.addQuadCurve(to: .init(x: 109, y: 42), control: .init(x: 123, y: 45))
            p.addQuadCurve(to: .init(x: 121, y: 57), control: .init(x: 122, y: 48))
            p.addQuadCurve(to: .init(x: 102, y: 52), control: .init(x: 110, y: 61))
            p.addQuadCurve(to: .init(x: 100, y: 69), control: .init(x: 108, y: 64))
            p.addQuadCurve(to: .init(x: 88, y: 54), control: .init(x: 89, y: 66))
            p.addQuadCurve(to: .init(x: 77, y: 68), control: .init(x: 85, y: 66))
            p.addQuadCurve(to: .init(x: 74, y: 51), control: .init(x: 70, y: 61))
            p.addQuadCurve(to: .init(x: 55, y: 58), control: .init(x: 65, y: 61))
            p.addQuadCurve(to: .init(x: 65, y: 43), control: .init(x: 56, y: 48))
            p.addQuadCurve(to: .init(x: 43, y: 37), control: .init(x: 50, y: 47))
            p.addQuadCurve(to: .init(x: 63, y: 31), control: .init(x: 51, y: 29))
            p.addQuadCurve(to: .init(x: 47, y: 22), control: .init(x: 50, y: 30))
            p.addQuadCurve(to: .init(x: 70, y: 25), control: .init(x: 58, y: 15)); p.closeSubpath()
        }
    }

    private static var frontPetals: Path {
        Path { p in
            p.move(to: .init(x: 74, y: 27))
            p.addCurve(to: .init(x: 66, y: 6), control1: .init(x: 66, y: 26), control2: .init(x: 61, y: 15))
            p.addCurve(to: .init(x: 83, y: 22), control1: .init(x: 79, y: 10), control2: .init(x: 82, y: 14)); p.closeSubpath()
            p.move(to: .init(x: 83, y: 22))
            p.addCurve(to: .init(x: 91, y: 3), control1: .init(x: 80, y: 12), control2: .init(x: 87, y: 9))
            p.addCurve(to: .init(x: 96, y: 23), control1: .init(x: 100, y: 13), control2: .init(x: 96, y: 18)); p.closeSubpath()
            p.move(to: .init(x: 97, y: 25))
            p.addCurve(to: .init(x: 115, y: 9), control1: .init(x: 98, y: 14), control2: .init(x: 109, y: 15))
            p.addCurve(to: .init(x: 103, y: 33), control1: .init(x: 118, y: 22), control2: .init(x: 109, y: 29)); p.closeSubpath()
            p.move(to: .init(x: 102, y: 34))
            p.addCurve(to: .init(x: 129, y: 27), control1: .init(x: 112, y: 26), control2: .init(x: 118, y: 31))
            p.addCurve(to: .init(x: 104, y: 42), control1: .init(x: 122, y: 39), control2: .init(x: 116, y: 42)); p.closeSubpath()
            p.move(to: .init(x: 100, y: 43))
            p.addCurve(to: .init(x: 122, y: 49), control1: .init(x: 110, y: 40), control2: .init(x: 116, y: 47))
            p.addCurve(to: .init(x: 96, y: 50), control1: .init(x: 115, y: 59), control2: .init(x: 103, y: 56)); p.closeSubpath()
            p.move(to: .init(x: 92, y: 48))
            p.addCurve(to: .init(x: 109, y: 65), control1: .init(x: 103, y: 48), control2: .init(x: 101, y: 60))
            p.addCurve(to: .init(x: 84, y: 51), control1: .init(x: 94, y: 70), control2: .init(x: 89, y: 58)); p.closeSubpath()
            p.move(to: .init(x: 82, y: 49))
            p.addCurve(to: .init(x: 86, y: 69), control1: .init(x: 90, y: 57), control2: .init(x: 82, y: 62))
            p.addCurve(to: .init(x: 73, y: 48), control1: .init(x: 72, y: 65), control2: .init(x: 70, y: 57)); p.closeSubpath()
            p.move(to: .init(x: 74, y: 43))
            p.addCurve(to: .init(x: 63, y: 63), control1: .init(x: 77, y: 52), control2: .init(x: 66, y: 57))
            p.addCurve(to: .init(x: 66, y: 39), control1: .init(x: 56, y: 55), control2: .init(x: 60, y: 44)); p.closeSubpath()
            p.move(to: .init(x: 69, y: 36))
            p.addCurve(to: .init(x: 46, y: 47), control1: .init(x: 64, y: 46), control2: .init(x: 54, y: 41))
            p.addCurve(to: .init(x: 69, y: 29), control1: .init(x: 48, y: 34), control2: .init(x: 62, y: 30)); p.closeSubpath()
            p.move(to: .init(x: 73, y: 28))
            p.addCurve(to: .init(x: 50, y: 18), control1: .init(x: 61, y: 32), control2: .init(x: 57, y: 22))
            p.addCurve(to: .init(x: 79, y: 23), control1: .init(x: 61, y: 12), control2: .init(x: 74, y: 16)); p.closeSubpath()
        }
    }

    private static var petalLight: Path {
        Path { p in
            p.move(to: .init(x: 68, y: 10)); p.addQuadCurve(to: .init(x: 78, y: 24), control: .init(x: 79, y: 15))
            p.addQuadCurve(to: .init(x: 68, y: 10), control: .init(x: 68, y: 23)); p.closeSubpath()
            p.move(to: .init(x: 91, y: 7)); p.addQuadCurve(to: .init(x: 92, y: 23), control: .init(x: 97, y: 16))
            p.addQuadCurve(to: .init(x: 91, y: 7), control: .init(x: 86, y: 19)); p.closeSubpath()
            p.move(to: .init(x: 112, y: 14)); p.addQuadCurve(to: .init(x: 101, y: 30), control: .init(x: 112, y: 24))
            p.addQuadCurve(to: .init(x: 112, y: 14), control: .init(x: 100, y: 20)); p.closeSubpath()
            p.move(to: .init(x: 54, y: 19)); p.addQuadCurve(to: .init(x: 75, y: 25), control: .init(x: 69, y: 16))
            p.addQuadCurve(to: .init(x: 54, y: 19), control: .init(x: 64, y: 27)); p.closeSubpath()
            p.move(to: .init(x: 50, y: 43)); p.addQuadCurve(to: .init(x: 68, y: 33), control: .init(x: 56, y: 33))
            p.addQuadCurve(to: .init(x: 50, y: 43), control: .init(x: 61, y: 41)); p.closeSubpath()
            p.move(to: .init(x: 104, y: 36)); p.addLine(to: .init(x: 124, y: 30))
            p.addQuadCurve(to: .init(x: 104, y: 36), control: .init(x: 113, y: 39)); p.closeSubpath()
        }
    }

    private static var petalFolds: Path {
        Path { p in
            p.move(to: .init(x: 74, y: 19)); p.addLine(to: .init(x: 79, y: 28))
            p.move(to: .init(x: 90, y: 13)); p.addLine(to: .init(x: 89, y: 23))
            p.move(to: .init(x: 108, y: 20)); p.addLine(to: .init(x: 99, y: 31))
            p.move(to: .init(x: 117, y: 34)); p.addLine(to: .init(x: 104, y: 38))
            p.move(to: .init(x: 109, y: 49)); p.addLine(to: .init(x: 100, y: 46))
            p.move(to: .init(x: 99, y: 59)); p.addLine(to: .init(x: 92, y: 50))
            p.move(to: .init(x: 79, y: 59)); p.addLine(to: .init(x: 79, y: 49))
            p.move(to: .init(x: 65, y: 53)); p.addLine(to: .init(x: 71, y: 44))
        }
    }

    private static var disk: Path {
        Path { p in
            p.move(to: .init(x: 71, y: 28))
            p.addCurve(to: .init(x: 90, y: 20), control1: .init(x: 76, y: 19), control2: .init(x: 84, y: 18))
            p.addCurve(to: .init(x: 103, y: 35), control1: .init(x: 99, y: 22), control2: .init(x: 104, y: 27))
            p.addCurve(to: .init(x: 86, y: 52), control1: .init(x: 102, y: 47), control2: .init(x: 94, y: 54))
            p.addCurve(to: .init(x: 71, y: 28), control1: .init(x: 70, y: 52), control2: .init(x: 65, y: 39)); p.closeSubpath()
        }
    }

    private static var diskEdge: Path {
        Path { p in
            p.move(to: .init(x: 72, y: 28))
            p.addCurve(to: .init(x: 99, y: 27), control1: .init(x: 78, y: 16), control2: .init(x: 93, y: 21))
            p.addCurve(to: .init(x: 96, y: 47), control1: .init(x: 107, y: 35), control2: .init(x: 101, y: 42))
            p.addCurve(to: .init(x: 72, y: 28), control1: .init(x: 105, y: 21), control2: .init(x: 80, y: 18)); p.closeSubpath()
        }
    }

    private static var diskLight: Path {
        Path { p in
            p.move(to: .init(x: 73, y: 30))
            p.addCurve(to: .init(x: 93, y: 25), control1: .init(x: 80, y: 21), control2: .init(x: 86, y: 21))
            p.addCurve(to: .init(x: 83, y: 43), control1: .init(x: 96, y: 32), control2: .init(x: 89, y: 39))
            p.addQuadCurve(to: .init(x: 73, y: 30), control: .init(x: 71, y: 45)); p.closeSubpath()
        }
    }

    private static var seeds: Path {
        Path { p in
            p.move(to: .init(x: 77, y: 29)); p.addLine(to: .init(x: 78, y: 27))
            p.move(to: .init(x: 84, y: 26)); p.addLine(to: .init(x: 86, y: 25))
            p.move(to: .init(x: 92, y: 28)); p.addLine(to: .init(x: 94, y: 29))
            p.move(to: .init(x: 97, y: 35)); p.addLine(to: .init(x: 97, y: 37))
            p.move(to: .init(x: 93, y: 44)); p.addLine(to: .init(x: 91, y: 45))
            p.move(to: .init(x: 83, y: 46)); p.addLine(to: .init(x: 81, y: 45))
            p.move(to: .init(x: 75, y: 39)); p.addLine(to: .init(x: 74, y: 37))
            p.move(to: .init(x: 81, y: 34)); p.addLine(to: .init(x: 82, y: 32))
            p.move(to: .init(x: 88, y: 33)); p.addLine(to: .init(x: 90, y: 34))
            p.move(to: .init(x: 86, y: 40)); p.addLine(to: .init(x: 84, y: 40))
        }
    }
}
