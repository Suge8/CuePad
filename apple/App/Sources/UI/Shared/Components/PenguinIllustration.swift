import SwiftUI

/// 冰缘上稍向左探身的企鹅：墨黑背、乳白腹、长翅鳍和短蹼足，左侧留冷空气。
nonisolated enum PenguinIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xC6E0E8, 0x89B4C6, 0x233D4B, 0x4F7489, 0xF4F1DF, 0xE3AB63], layers: [
            .init(path: distantIce, ink: 4, coverage: 0.48),
            .init(path: iceEdge, ink: 1),
            .init(path: ice, ink: 4),
            .init(path: iceShade, ink: 1, coverage: 0.38),
            .init(path: Path(ellipseIn: CGRect(x: 120, y: 81, width: 63, height: 8)), ink: 3, coverage: 0.4),
            .init(path: feet, ink: 5),
            .init(path: farFlipper, ink: 3),
            .init(path: body, ink: 2),
            .init(path: backLight, ink: 3, coverage: 0.65),
            .init(path: belly, ink: 4),
            .init(path: bellyShade, ink: 1, coverage: 0.5),
            .init(path: cheek, ink: 4),
            .init(path: collar, ink: 5, coverage: 0.75),
            .init(path: flipper, ink: 2),
            .init(path: flipperLight, ink: 3, coverage: 0.72),
            .init(path: beak, ink: 5),
            .init(path: beakLine.strokedPath(StrokeStyle(lineWidth: 0.8)), ink: 2),
            .init(path: Path(ellipseIn: CGRect(x: 131, y: 25, width: 2.8, height: 2.8)), ink: 4),
            .init(path: Path(ellipseIn: CGRect(x: 131, y: 25.5, width: 1.4, height: 1.6)), ink: 2),
            .init(path: iceCracks.strokedPath(StrokeStyle(lineWidth: 0.8)), ink: 1)
        ])
    }

    private static var distantIce: Path {
        Path { p in
            p.move(to: .init(x: 0, y: 66)); p.addLine(to: .init(x: 32, y: 62))
            p.addLine(to: .init(x: 56, y: 65)); p.addLine(to: .init(x: 80, y: 62))
            p.addLine(to: .init(x: 99, y: 68)); p.addLine(to: .init(x: 0, y: 70)); p.closeSubpath()
        }
    }

    private static var ice: Path {
        Path { p in
            p.move(to: .init(x: 69, y: 83)); p.addLine(to: .init(x: 104, y: 77))
            p.addLine(to: .init(x: 167, y: 76)); p.addLine(to: .init(x: 201, y: 82))
            p.addLine(to: .init(x: 193, y: 89)); p.addLine(to: .init(x: 113, y: 94))
            p.addLine(to: .init(x: 79, y: 90)); p.closeSubpath()
        }
    }

    private static var iceEdge: Path {
        Path { p in
            p.move(to: .init(x: 69, y: 83)); p.addLine(to: .init(x: 115, y: 87))
            p.addLine(to: .init(x: 201, y: 82)); p.addLine(to: .init(x: 192, y: 94))
            p.addLine(to: .init(x: 114, y: 99)); p.addLine(to: .init(x: 80, y: 95)); p.closeSubpath()
        }
    }

    private static var iceShade: Path {
        Path { p in
            p.move(to: .init(x: 79, y: 88)); p.addLine(to: .init(x: 113, y: 90))
            p.addLine(to: .init(x: 193, y: 86)); p.addLine(to: .init(x: 193, y: 89))
            p.addLine(to: .init(x: 113, y: 94)); p.closeSubpath()
        }
    }

    private static var feet: Path {
        Path { p in
            p.move(to: .init(x: 133, y: 77)); p.addLine(to: .init(x: 143, y: 79))
            p.addLine(to: .init(x: 142, y: 85)); p.addLine(to: .init(x: 122, y: 85))
            p.addLine(to: .init(x: 125, y: 82)); p.addLine(to: .init(x: 131, y: 81)); p.closeSubpath()
            p.move(to: .init(x: 153, y: 78)); p.addLine(to: .init(x: 161, y: 77))
            p.addLine(to: .init(x: 163, y: 81)); p.addLine(to: .init(x: 172, y: 84))
            p.addLine(to: .init(x: 171, y: 87)); p.addLine(to: .init(x: 153, y: 85)); p.closeSubpath()
        }
    }

    private static var farFlipper: Path {
        Path { p in
            p.move(to: .init(x: 130, y: 41)); p.addQuadCurve(to: .init(x: 109, y: 62), control: .init(x: 116, y: 46))
            p.addQuadCurve(to: .init(x: 107, y: 68), control: .init(x: 105, y: 68))
            p.addQuadCurve(to: .init(x: 132, y: 57), control: .init(x: 123, y: 65)); p.closeSubpath()
        }
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 123, y: 29))
            p.addCurve(to: .init(x: 146, y: 15), control1: .init(x: 122, y: 14), control2: .init(x: 137, y: 10))
            p.addCurve(to: .init(x: 158, y: 40), control1: .init(x: 158, y: 19), control2: .init(x: 152, y: 30))
            p.addCurve(to: .init(x: 169, y: 71), control1: .init(x: 168, y: 52), control2: .init(x: 174, y: 65))
            p.addLine(to: .init(x: 174, y: 79)); p.addLine(to: .init(x: 163, y: 78))
            p.addQuadCurve(to: .init(x: 134, y: 81), control: .init(x: 154, y: 86))
            p.addCurve(to: .init(x: 124, y: 50), control1: .init(x: 122, y: 77), control2: .init(x: 119, y: 64))
            p.addQuadCurve(to: .init(x: 123, y: 29), control: .init(x: 129, y: 37)); p.closeSubpath()
        }
    }

    private static var backLight: Path {
        Path { p in
            p.move(to: .init(x: 138, y: 15)); p.addQuadCurve(to: .init(x: 152, y: 31), control: .init(x: 154, y: 15))
            p.addQuadCurve(to: .init(x: 167, y: 70), control: .init(x: 163, y: 43))
            p.addLine(to: .init(x: 158, y: 67)); p.addQuadCurve(to: .init(x: 145, y: 34), control: .init(x: 159, y: 47))
            p.addQuadCurve(to: .init(x: 138, y: 15), control: .init(x: 148, y: 21)); p.closeSubpath()
        }
    }

    private static var belly: Path {
        Path { p in
            p.move(to: .init(x: 129, y: 39)); p.addQuadCurve(to: .init(x: 144, y: 43), control: .init(x: 136, y: 46))
            p.addCurve(to: .init(x: 158, y: 72), control1: .init(x: 155, y: 48), control2: .init(x: 162, y: 65))
            p.addQuadCurve(to: .init(x: 135, y: 79), control: .init(x: 157, y: 83))
            p.addCurve(to: .init(x: 125, y: 52), control1: .init(x: 124, y: 75), control2: .init(x: 122, y: 62))
            p.closeSubpath()
        }
    }

    private static var bellyShade: Path {
        Path { p in
            p.move(to: .init(x: 142, y: 46)); p.addQuadCurve(to: .init(x: 158, y: 72), control: .init(x: 161, y: 59))
            p.addQuadCurve(to: .init(x: 135, y: 79), control: .init(x: 157, y: 83))
            p.addQuadCurve(to: .init(x: 149, y: 67), control: .init(x: 151, y: 79))
            p.addQuadCurve(to: .init(x: 142, y: 46), control: .init(x: 152, y: 56)); p.closeSubpath()
        }
    }

    private static var cheek: Path {
        Path { p in
            p.move(to: .init(x: 126, y: 32)); p.addQuadCurve(to: .init(x: 138, y: 30), control: .init(x: 131, y: 35))
            p.addQuadCurve(to: .init(x: 143, y: 28), control: .init(x: 145, y: 21))
            p.addQuadCurve(to: .init(x: 138, y: 40), control: .init(x: 148, y: 36))
            p.addQuadCurve(to: .init(x: 128, y: 37), control: .init(x: 132, y: 42)); p.closeSubpath()
        }
    }

    private static var collar: Path {
        Path { p in
            p.move(to: .init(x: 128, y: 38)); p.addQuadCurve(to: .init(x: 143, y: 37), control: .init(x: 138, y: 44))
            p.addLine(to: .init(x: 145, y: 44)); p.addQuadCurve(to: .init(x: 129, y: 45), control: .init(x: 134, y: 49))
            p.closeSubpath()
        }
    }

    private static var flipper: Path {
        Path { p in
            p.move(to: .init(x: 151, y: 41))
            p.addCurve(to: .init(x: 180, y: 72), control1: .init(x: 164, y: 47), control2: .init(x: 174, y: 61))
            p.addQuadCurve(to: .init(x: 178, y: 77), control: .init(x: 183, y: 79))
            p.addCurve(to: .init(x: 149, y: 50), control1: .init(x: 162, y: 71), control2: .init(x: 155, y: 60))
            p.closeSubpath()
        }
    }

    private static var flipperLight: Path {
        Path { p in
            p.move(to: .init(x: 154, y: 44)); p.addQuadCurve(to: .init(x: 177, y: 71), control: .init(x: 170, y: 57))
            p.addQuadCurve(to: .init(x: 156, y: 55), control: .init(x: 162, y: 65)); p.closeSubpath()
        }
    }

    private static var beak: Path {
        Path { p in
            p.move(to: .init(x: 125, y: 29)); p.addLine(to: .init(x: 111, y: 33))
            p.addLine(to: .init(x: 126, y: 36)); p.addLine(to: .init(x: 130, y: 33)); p.closeSubpath()
        }
    }

    private static var beakLine: Path {
        Path { p in
            p.move(to: .init(x: 112, y: 33)); p.addLine(to: .init(x: 125, y: 33))
        }
    }

    private static var iceCracks: Path {
        Path { p in
            p.move(to: .init(x: 89, y: 82)); p.addLine(to: .init(x: 107, y: 85)); p.addLine(to: .init(x: 99, y: 88))
            p.move(to: .init(x: 180, y: 87)); p.addLine(to: .init(x: 185, y: 83)); p.addLine(to: .init(x: 194, y: 84))
        }
    }
}
