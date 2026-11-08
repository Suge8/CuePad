import SwiftUI

/// 苔地上三朵红伞：左后的小伞、中央高伞与右前的幼菇依次叠放，奶油菌褶托住莓红伞盖。
nonisolated enum MushroomIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0x293B32, 0x71845B, 0xEFE5CB, 0x4A302C, 0xAB4457, 0xD97E83], layers: [
            .init(path: moss, ink: 1, coverage: 0.32),
            .init(path: rearStem, ink: 2, coverage: 0.8),
            .init(path: rearCap, ink: 4),
            .init(path: rearCapLight, ink: 5, coverage: 0.5),
            .init(path: rearRim.strokedPath(StrokeStyle(lineWidth: 1.5)), ink: 2),
            .init(path: rearSpots, ink: 2),
            .init(path: mainStem, ink: 2),
            .init(path: stemShade, ink: 3, coverage: 0.3),
            .init(path: stemFibers.strokedPath(StrokeStyle(lineWidth: 0.75)), ink: 3, coverage: 0.45),
            .init(path: skirt, ink: 2),
            .init(path: mainCap, ink: 3),
            .init(path: gills, ink: 2),
            .init(path: gillLines.strokedPath(StrokeStyle(lineWidth: 0.8)), ink: 3, coverage: 0.65),
            .init(path: capCrown, ink: 4),
            .init(path: capLight, ink: 5, coverage: 0.62),
            .init(path: capShade, ink: 3, coverage: 0.35),
            .init(path: capSpots, ink: 2),
            .init(path: frontStem, ink: 2),
            .init(path: frontStemShade, ink: 3, coverage: 0.35),
            .init(path: frontCap, ink: 4),
            .init(path: frontLight, ink: 5, coverage: 0.6),
            .init(path: frontRim.strokedPath(StrokeStyle(lineWidth: 1.7)), ink: 2),
            .init(path: frontSpots, ink: 2),
            .init(path: leaves, ink: 1),
            .init(path: leafVeins.strokedPath(StrokeStyle(lineWidth: 0.8)), ink: 2, coverage: 0.55)
        ])
    }

    private static var moss: Path {
        Path { p in
            p.move(to: .init(x: 32, y: 88))
            p.addCurve(to: .init(x: 190, y: 86), control1: .init(x: 60, y: 74), control2: .init(x: 156, y: 76))
            p.addQuadCurve(to: .init(x: 174, y: 95), control: .init(x: 204, y: 94))
            p.addQuadCurve(to: .init(x: 32, y: 88), control: .init(x: 86, y: 104)); p.closeSubpath()
        }
    }

    private static var rearStem: Path {
        Path { p in
            p.move(to: .init(x: 61, y: 55)); p.addLine(to: .init(x: 69, y: 55))
            p.addQuadCurve(to: .init(x: 76, y: 82), control: .init(x: 69, y: 71))
            p.addQuadCurve(to: .init(x: 62, y: 84), control: .init(x: 68, y: 86))
            p.addQuadCurve(to: .init(x: 61, y: 55), control: .init(x: 64, y: 73)); p.closeSubpath()
        }
    }

    private static var rearCap: Path {
        Path { p in
            p.move(to: .init(x: 43, y: 56))
            p.addCurve(to: .init(x: 61, y: 37), control1: .init(x: 45, y: 45), control2: .init(x: 50, y: 36))
            p.addCurve(to: .init(x: 88, y: 55), control1: .init(x: 74, y: 34), control2: .init(x: 84, y: 47))
            p.addQuadCurve(to: .init(x: 43, y: 56), control: .init(x: 69, y: 66)); p.closeSubpath()
        }
    }

    private static var rearCapLight: Path {
        Path { p in
            p.move(to: .init(x: 46, y: 52))
            p.addQuadCurve(to: .init(x: 72, y: 40), control: .init(x: 53, y: 33))
            p.addQuadCurve(to: .init(x: 46, y: 52), control: .init(x: 57, y: 42)); p.closeSubpath()
        }
    }

    private static var rearRim: Path {
        Path { p in
            p.move(to: .init(x: 44, y: 56)); p.addQuadCurve(to: .init(x: 86, y: 56), control: .init(x: 65, y: 63))
        }
    }

    private static var rearSpots: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 56, y: 40, width: 5, height: 3))
            p.addEllipse(in: CGRect(x: 48, y: 49, width: 4, height: 2.5))
            p.addEllipse(in: CGRect(x: 65, y: 48, width: 6, height: 3.5))
            p.addEllipse(in: CGRect(x: 76, y: 50, width: 3, height: 2))
        }
    }

    private static var mainStem: Path {
        Path { p in
            p.move(to: .init(x: 108, y: 43)); p.addLine(to: .init(x: 123, y: 42))
            p.addCurve(to: .init(x: 125, y: 84), control1: .init(x: 119, y: 58), control2: .init(x: 117, y: 74))
            p.addCurve(to: .init(x: 104, y: 87), control1: .init(x: 129, y: 92), control2: .init(x: 104, y: 94))
            p.addCurve(to: .init(x: 108, y: 43), control1: .init(x: 102, y: 75), control2: .init(x: 111, y: 57)); p.closeSubpath()
        }
    }

    private static var stemShade: Path {
        Path { p in
            p.move(to: .init(x: 115, y: 45)); p.addLine(to: .init(x: 123, y: 43))
            p.addCurve(to: .init(x: 125, y: 84), control1: .init(x: 119, y: 58), control2: .init(x: 117, y: 74))
            p.addQuadCurve(to: .init(x: 115, y: 90), control: .init(x: 129, y: 90))
            p.addQuadCurve(to: .init(x: 115, y: 45), control: .init(x: 109, y: 70)); p.closeSubpath()
        }
    }

    private static var stemFibers: Path {
        Path { p in
            p.move(to: .init(x: 111, y: 64)); p.addQuadCurve(to: .init(x: 108, y: 84), control: .init(x: 107, y: 77))
            p.move(to: .init(x: 115, y: 69)); p.addQuadCurve(to: .init(x: 117, y: 86), control: .init(x: 113, y: 79))
        }
    }

    private static var skirt: Path {
        Path { p in
            p.move(to: .init(x: 107, y: 55)); p.addLine(to: .init(x: 121, y: 53))
            p.addQuadCurve(to: .init(x: 125, y: 62), control: .init(x: 119, y: 59))
            p.addLine(to: .init(x: 118, y: 61)); p.addLine(to: .init(x: 115, y: 64))
            p.addLine(to: .init(x: 111, y: 62)); p.addLine(to: .init(x: 103, y: 64))
            p.addQuadCurve(to: .init(x: 107, y: 55), control: .init(x: 107, y: 58)); p.closeSubpath()
        }
    }

    private static var mainCap: Path {
        Path { p in
            p.move(to: .init(x: 72, y: 44))
            p.addCurve(to: .init(x: 117, y: 14), control1: .init(x: 82, y: 25), control2: .init(x: 98, y: 10))
            p.addCurve(to: .init(x: 160, y: 42), control1: .init(x: 139, y: 14), control2: .init(x: 149, y: 30))
            p.addCurve(to: .init(x: 119, y: 53), control1: .init(x: 166, y: 48), control2: .init(x: 142, y: 54))
            p.addQuadCurve(to: .init(x: 72, y: 44), control: .init(x: 82, y: 57)); p.closeSubpath()
        }
    }

    private static var gills: Path {
        Path { p in
            p.move(to: .init(x: 76, y: 44)); p.addQuadCurve(to: .init(x: 157, y: 43), control: .init(x: 119, y: 34))
            p.addQuadCurve(to: .init(x: 119, y: 51), control: .init(x: 149, y: 52))
            p.addQuadCurve(to: .init(x: 76, y: 44), control: .init(x: 88, y: 54)); p.closeSubpath()
        }
    }

    private static var gillLines: Path {
        Path { p in
            for point in [CGPoint(x: 80, y: 45), .init(x: 91, y: 49), .init(x: 102, y: 51), .init(x: 132, y: 50), .init(x: 143, y: 48), .init(x: 154, y: 44)] {
                p.move(to: .init(x: 116, y: 42)); p.addLine(to: point)
            }
        }
    }

    private static var capCrown: Path {
        Path { p in
            p.move(to: .init(x: 72, y: 44))
            p.addCurve(to: .init(x: 117, y: 14), control1: .init(x: 82, y: 25), control2: .init(x: 98, y: 10))
            p.addCurve(to: .init(x: 160, y: 42), control1: .init(x: 139, y: 14), control2: .init(x: 149, y: 30))
            p.addCurve(to: .init(x: 111, y: 41), control1: .init(x: 150, y: 45), control2: .init(x: 128, y: 40))
            p.addQuadCurve(to: .init(x: 72, y: 44), control: .init(x: 87, y: 41)); p.closeSubpath()
        }
    }

    private static var capLight: Path {
        Path { p in
            p.move(to: .init(x: 79, y: 38))
            p.addCurve(to: .init(x: 126, y: 18), control1: .init(x: 92, y: 16), control2: .init(x: 109, y: 10))
            p.addQuadCurve(to: .init(x: 141, y: 29), control: .init(x: 136, y: 21))
            p.addCurve(to: .init(x: 79, y: 38), control1: .init(x: 115, y: 24), control2: .init(x: 99, y: 24)); p.closeSubpath()
        }
    }

    private static var capShade: Path {
        Path { p in
            p.move(to: .init(x: 140, y: 27)); p.addQuadCurve(to: .init(x: 159, y: 42), control: .init(x: 153, y: 33))
            p.addLine(to: .init(x: 119, y: 41))
            p.addQuadCurve(to: .init(x: 140, y: 27), control: .init(x: 144, y: 40)); p.closeSubpath()
        }
    }

    private static var capSpots: Path {
        Path { p in
            p.move(to: .init(x: 104, y: 18)); p.addQuadCurve(to: .init(x: 114, y: 17), control: .init(x: 109, y: 15))
            p.addLine(to: .init(x: 116, y: 21)); p.addQuadCurve(to: .init(x: 103, y: 22), control: .init(x: 109, y: 24)); p.closeSubpath()
            p.move(to: .init(x: 91, y: 27)); p.addQuadCurve(to: .init(x: 99, y: 26), control: .init(x: 95, y: 23))
            p.addLine(to: .init(x: 101, y: 30)); p.addQuadCurve(to: .init(x: 89, y: 32), control: .init(x: 95, y: 34)); p.closeSubpath()
            p.addEllipse(in: CGRect(x: 122, y: 23, width: 8, height: 5))
            p.addEllipse(in: CGRect(x: 109, y: 32, width: 9, height: 5))
            p.addEllipse(in: CGRect(x: 137, y: 32, width: 7, height: 4))
            p.addEllipse(in: CGRect(x: 81, y: 37, width: 5, height: 2.5))
            p.addEllipse(in: CGRect(x: 125, y: 37, width: 4, height: 2.5))
        }
    }

    private static var frontStem: Path {
        Path { p in
            p.move(to: .init(x: 154, y: 73)); p.addLine(to: .init(x: 164, y: 74))
            p.addQuadCurve(to: .init(x: 166, y: 90), control: .init(x: 162, y: 83))
            p.addQuadCurve(to: .init(x: 151, y: 91), control: .init(x: 159, y: 94))
            p.addQuadCurve(to: .init(x: 154, y: 73), control: .init(x: 155, y: 82)); p.closeSubpath()
        }
    }

    private static var frontStemShade: Path {
        Path { p in
            p.move(to: .init(x: 159, y: 74)); p.addLine(to: .init(x: 164, y: 74))
            p.addQuadCurve(to: .init(x: 166, y: 90), control: .init(x: 162, y: 83))
            p.addLine(to: .init(x: 159, y: 92)); p.closeSubpath()
        }
    }

    private static var frontCap: Path {
        Path { p in
            p.move(to: .init(x: 136, y: 72))
            p.addCurve(to: .init(x: 157, y: 57), control1: .init(x: 139, y: 61), control2: .init(x: 146, y: 55))
            p.addCurve(to: .init(x: 183, y: 74), control1: .init(x: 171, y: 57), control2: .init(x: 180, y: 64))
            p.addQuadCurve(to: .init(x: 136, y: 72), control: .init(x: 159, y: 84)); p.closeSubpath()
        }
    }

    private static var frontLight: Path {
        Path { p in
            p.move(to: .init(x: 139, y: 69))
            p.addQuadCurve(to: .init(x: 171, y: 62), control: .init(x: 149, y: 51))
            p.addQuadCurve(to: .init(x: 139, y: 69), control: .init(x: 153, y: 61)); p.closeSubpath()
        }
    }

    private static var frontRim: Path {
        Path { p in
            p.move(to: .init(x: 137, y: 73)); p.addQuadCurve(to: .init(x: 182, y: 74), control: .init(x: 158, y: 80))
        }
    }

    private static var frontSpots: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 151, y: 59, width: 7, height: 3.5))
            p.addEllipse(in: CGRect(x: 142, y: 67, width: 5, height: 3))
            p.addEllipse(in: CGRect(x: 158, y: 68, width: 7, height: 4))
            p.addEllipse(in: CGRect(x: 171, y: 66, width: 4, height: 3))
        }
    }

    private static var leaves: Path {
        Path { p in
            p.move(to: .init(x: 55, y: 88))
            p.addCurve(to: .init(x: 31, y: 65), control1: .init(x: 37, y: 85), control2: .init(x: 37, y: 74))
            p.addCurve(to: .init(x: 55, y: 88), control1: .init(x: 53, y: 65), control2: .init(x: 59, y: 77)); p.closeSubpath()
            p.move(to: .init(x: 58, y: 89))
            p.addCurve(to: .init(x: 86, y: 76), control1: .init(x: 62, y: 76), control2: .init(x: 72, y: 80))
            p.addCurve(to: .init(x: 58, y: 89), control1: .init(x: 81, y: 92), control2: .init(x: 68, y: 94)); p.closeSubpath()
            p.move(to: .init(x: 175, y: 91))
            p.addCurve(to: .init(x: 195, y: 74), control1: .init(x: 173, y: 76), control2: .init(x: 188, y: 82))
            p.addCurve(to: .init(x: 175, y: 91), control1: .init(x: 194, y: 89), control2: .init(x: 183, y: 95)); p.closeSubpath()
        }
    }

    private static var leafVeins: Path {
        Path { p in
            p.move(to: .init(x: 38, y: 72)); p.addQuadCurve(to: .init(x: 58, y: 90), control: .init(x: 45, y: 82))
            p.addQuadCurve(to: .init(x: 78, y: 82), control: .init(x: 70, y: 87))
            p.move(to: .init(x: 178, y: 90)); p.addLine(to: .init(x: 189, y: 82))
        }
    }
}
