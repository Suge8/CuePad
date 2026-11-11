import SwiftUI

/// 夜海中上浮的水母：透光伞盖、放射状内腔、褶皱口腕与被水流带开的长触手。
nonisolated enum JellyfishIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0x252342, 0x403969, 0x7063A1, 0xAB8BC1, 0xEAC5DA, 0xB4BDE3], layers: [
            .init(path: distantGlow, ink: 1, coverage: 0.5),
            .init(path: distantPlankton, ink: 3, coverage: 0.5),
            .init(path: trailingThreads.strokedPath(StrokeStyle(lineWidth: 1.1, lineCap: .round)), ink: 3),
            .init(path: farArms, ink: 2),
            .init(path: oralArms, ink: 3),
            .init(path: armFolds, ink: 4, coverage: 0.65),
            .init(path: bell, ink: 2),
            .init(path: bellLight, ink: 3, coverage: 0.7),
            .init(path: crown, ink: 4, coverage: 0.65),
            .init(path: chamber, ink: 1, coverage: 0.55),
            .init(path: innerPetals, ink: 3, coverage: 0.7),
            .init(path: meridians.strokedPath(StrokeStyle(lineWidth: 0.85, lineCap: .round)), ink: 5, coverage: 0.75),
            .init(path: rim.strokedPath(StrokeStyle(lineWidth: 1.8, lineCap: .round)), ink: 4),
            .init(path: brightThreads.strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round)), ink: 4),
            .init(path: nearPlankton, ink: 5)
        ])
    }

    private static var distantGlow: Path {
        Path { p in
            p.move(to: .init(x: 60, y: 0))
            p.addCurve(to: .init(x: 166, y: 57), control1: .init(x: 169, y: -9), control2: .init(x: 193, y: 27))
            p.addCurve(to: .init(x: 60, y: 0), control1: .init(x: 125, y: 36), control2: .init(x: 53, y: 48))
            p.closeSubpath()
        }
    }

    private static var bell: Path {
        Path { p in
            p.move(to: .init(x: 76, y: 43))
            p.addCurve(to: .init(x: 107, y: 12), control1: .init(x: 79, y: 25), control2: .init(x: 91, y: 12))
            p.addCurve(to: .init(x: 148, y: 36), control1: .init(x: 129, y: 8), control2: .init(x: 144, y: 19))
            p.addQuadCurve(to: .init(x: 151, y: 44), control: .init(x: 149, y: 41))
            p.addQuadCurve(to: .init(x: 138, y: 48), control: .init(x: 146, y: 50))
            p.addQuadCurve(to: .init(x: 124, y: 51), control: .init(x: 130, y: 54))
            p.addQuadCurve(to: .init(x: 109, y: 52), control: .init(x: 116, y: 56))
            p.addQuadCurve(to: .init(x: 94, y: 50), control: .init(x: 100, y: 55))
            p.addQuadCurve(to: .init(x: 76, y: 43), control: .init(x: 80, y: 52))
            p.closeSubpath()
        }
    }

    private static var bellLight: Path {
        Path { p in
            p.move(to: .init(x: 78, y: 40))
            p.addCurve(to: .init(x: 108, y: 13), control1: .init(x: 83, y: 24), control2: .init(x: 95, y: 12))
            p.addCurve(to: .init(x: 143, y: 30), control1: .init(x: 126, y: 11), control2: .init(x: 138, y: 19))
            p.addCurve(to: .init(x: 110, y: 28), control1: .init(x: 134, y: 25), control2: .init(x: 124, y: 24))
            p.addQuadCurve(to: .init(x: 78, y: 40), control: .init(x: 91, y: 28))
            p.closeSubpath()
        }
    }

    private static var crown: Path {
        Path { p in
            p.move(to: .init(x: 86, y: 29))
            p.addCurve(to: .init(x: 130, y: 19), control1: .init(x: 94, y: 14), control2: .init(x: 117, y: 11))
            p.addCurve(to: .init(x: 86, y: 29), control1: .init(x: 112, y: 17), control2: .init(x: 97, y: 22))
            p.closeSubpath()
        }
    }

    private static var chamber: Path {
        Path { p in
            p.move(to: .init(x: 81, y: 43))
            p.addCurve(to: .init(x: 146, y: 42), control1: .init(x: 98, y: 33), control2: .init(x: 133, y: 33))
            p.addCurve(to: .init(x: 81, y: 43), control1: .init(x: 141, y: 54), control2: .init(x: 95, y: 56))
            p.closeSubpath()
        }
    }

    private static var innerPetals: Path {
        Path { p in
            p.move(to: .init(x: 111, y: 44))
            p.addCurve(to: .init(x: 104, y: 31), control1: .init(x: 95, y: 42), control2: .init(x: 95, y: 31))
            p.addQuadCurve(to: .init(x: 114, y: 41), control: .init(x: 111, y: 29))
            p.addCurve(to: .init(x: 127, y: 34), control1: .init(x: 117, y: 29), control2: .init(x: 126, y: 29))
            p.addQuadCurve(to: .init(x: 119, y: 45), control: .init(x: 132, y: 40))
            p.addQuadCurve(to: .init(x: 111, y: 44), control: .init(x: 116, y: 51))
            p.closeSubpath()
        }
    }

    private static var meridians: Path {
        Path { p in
            p.move(to: .init(x: 106, y: 17)); p.addQuadCurve(to: .init(x: 91, y: 42), control: .init(x: 94, y: 22))
            p.move(to: .init(x: 113, y: 16)); p.addQuadCurve(to: .init(x: 108, y: 36), control: .init(x: 106, y: 24))
            p.move(to: .init(x: 119, y: 17)); p.addQuadCurve(to: .init(x: 132, y: 40), control: .init(x: 130, y: 24))
            p.move(to: .init(x: 126, y: 19)); p.addQuadCurve(to: .init(x: 144, y: 40), control: .init(x: 139, y: 25))
        }
    }

    private static var rim: Path {
        Path { p in
            p.move(to: .init(x: 77, y: 43))
            p.addQuadCurve(to: .init(x: 94, y: 49), control: .init(x: 82, y: 51))
            p.addQuadCurve(to: .init(x: 109, y: 51), control: .init(x: 101, y: 54))
            p.addQuadCurve(to: .init(x: 124, y: 50), control: .init(x: 116, y: 55))
            p.addQuadCurve(to: .init(x: 138, y: 47), control: .init(x: 131, y: 53))
            p.addQuadCurve(to: .init(x: 150, y: 44), control: .init(x: 146, y: 49))
        }
    }

    private static var farArms: Path {
        Path { p in
            p.move(to: .init(x: 99, y: 45))
            p.addCurve(to: .init(x: 85, y: 72), control1: .init(x: 103, y: 60), control2: .init(x: 79, y: 60))
            p.addCurve(to: .init(x: 103, y: 88), control1: .init(x: 89, y: 81), control2: .init(x: 103, y: 77))
            p.addCurve(to: .init(x: 94, y: 68), control1: .init(x: 113, y: 78), control2: .init(x: 88, y: 75))
            p.addQuadCurve(to: .init(x: 109, y: 45), control: .init(x: 113, y: 59)); p.closeSubpath()
            p.move(to: .init(x: 121, y: 45))
            p.addCurve(to: .init(x: 142, y: 69), control1: .init(x: 117, y: 60), control2: .init(x: 150, y: 56))
            p.addQuadCurve(to: .init(x: 151, y: 83), control: .init(x: 135, y: 78))
            p.addQuadCurve(to: .init(x: 150, y: 64), control: .init(x: 143, y: 76))
            p.addQuadCurve(to: .init(x: 131, y: 44), control: .init(x: 135, y: 51)); p.closeSubpath()
        }
    }

    private static var oralArms: Path {
        Path { p in
            p.move(to: .init(x: 108, y: 44))
            p.addQuadCurve(to: .init(x: 105, y: 58), control: .init(x: 99, y: 53))
            p.addQuadCurve(to: .init(x: 111, y: 66), control: .init(x: 117, y: 58))
            p.addQuadCurve(to: .init(x: 113, y: 76), control: .init(x: 100, y: 73))
            p.addQuadCurve(to: .init(x: 126, y: 90), control: .init(x: 127, y: 77))
            p.addQuadCurve(to: .init(x: 120, y: 72), control: .init(x: 133, y: 81))
            p.addQuadCurve(to: .init(x: 121, y: 62), control: .init(x: 130, y: 68))
            p.addQuadCurve(to: .init(x: 118, y: 53), control: .init(x: 111, y: 60))
            p.addLine(to: .init(x: 119, y: 45)); p.closeSubpath()
        }
    }

    private static var armFolds: Path {
        Path { p in
            p.move(to: .init(x: 108, y: 48)); p.addQuadCurve(to: .init(x: 112, y: 59), control: .init(x: 104, y: 56))
            p.addLine(to: .init(x: 119, y: 61)); p.addQuadCurve(to: .init(x: 115, y: 53), control: .init(x: 112, y: 56)); p.closeSubpath()
            p.move(to: .init(x: 112, y: 67)); p.addQuadCurve(to: .init(x: 119, y: 77), control: .init(x: 106, y: 74))
            p.addLine(to: .init(x: 124, y: 81)); p.addQuadCurve(to: .init(x: 118, y: 71), control: .init(x: 124, y: 75)); p.closeSubpath()
        }
    }

    private static var trailingThreads: Path {
        Path { p in
            p.move(to: .init(x: 82, y: 45))
            p.addCurve(to: .init(x: 60, y: 70), control1: .init(x: 83, y: 62), control2: .init(x: 58, y: 56))
            p.addCurve(to: .init(x: 73, y: 91), control1: .init(x: 62, y: 81), control2: .init(x: 79, y: 80))
            p.move(to: .init(x: 94, y: 49))
            p.addCurve(to: .init(x: 80, y: 78), control1: .init(x: 96, y: 64), control2: .init(x: 75, y: 66))
            p.addQuadCurve(to: .init(x: 95, y: 96), control: .init(x: 87, y: 87))
            p.move(to: .init(x: 139, y: 46))
            p.addCurve(to: .init(x: 164, y: 69), control1: .init(x: 137, y: 61), control2: .init(x: 166, y: 55))
            p.addCurve(to: .init(x: 152, y: 95), control1: .init(x: 163, y: 82), control2: .init(x: 146, y: 80))
            p.move(to: .init(x: 148, y: 44))
            p.addCurve(to: .init(x: 179, y: 63), control1: .init(x: 153, y: 57), control2: .init(x: 173, y: 52))
            p.addQuadCurve(to: .init(x: 175, y: 82), control: .init(x: 186, y: 74))
        }
    }

    private static var brightThreads: Path {
        Path { p in
            p.move(to: .init(x: 88, y: 48))
            p.addCurve(to: .init(x: 72, y: 72), control1: .init(x: 89, y: 63), control2: .init(x: 66, y: 61))
            p.addQuadCurve(to: .init(x: 83, y: 83), control: .init(x: 76, y: 78))
            p.move(to: .init(x: 130, y: 50))
            p.addCurve(to: .init(x: 131, y: 78), control1: .init(x: 123, y: 63), control2: .init(x: 146, y: 67))
            p.addQuadCurve(to: .init(x: 139, y: 96), control: .init(x: 122, y: 90))
        }
    }

    private static var distantPlankton: Path {
        Path { p in
            for point in [CGPoint(x: 43, y: 31), .init(x: 59, y: 13), .init(x: 173, y: 24), .init(x: 191, y: 53)] {
                p.addEllipse(in: CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5))
            }
        }
    }

    private static var nearPlankton: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 48, y: 77, width: 2.2, height: 2.2))
            p.addEllipse(in: CGRect(x: 165, y: 40, width: 1.8, height: 1.8))
            p.addEllipse(in: CGRect(x: 188, y: 88, width: 2.4, height: 2.4))
        }
    }
}
