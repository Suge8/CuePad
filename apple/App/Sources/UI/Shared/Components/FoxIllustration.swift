import SwiftUI

/// 回望草丛的赤狐：窄长吻与高耳朝左，肩背转向右，白尖蓬尾压低画面重心。
nonisolated enum FoxIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xC6C9AD, 0x7E8965, 0x493A30, 0x984B35, 0xD78046, 0xF4E4BF], layers: [
            .init(path: grasses, ink: 1, coverage: 0.58),
            .init(path: Path(ellipseIn: CGRect(x: 57, y: 83, width: 132, height: 9)), ink: 1, coverage: 0.6),
            .init(path: body, ink: 3),
            .init(path: shoulder, ink: 4),
            .init(path: shoulderShade, ink: 3, coverage: 0.48),
            .init(path: legs, ink: 2),
            .init(path: bib, ink: 5),
            .init(path: bibShade, ink: 4, coverage: 0.4),
            .init(path: tail, ink: 4),
            .init(path: tailShade, ink: 3, coverage: 0.68),
            .init(path: tailTip, ink: 5),
            .init(path: head, ink: 4),
            .init(path: ears, ink: 2),
            .init(path: earLight, ink: 5, coverage: 0.65),
            .init(path: cheek, ink: 5),
            .init(path: brow, ink: 3, coverage: 0.7),
            .init(path: features, ink: 2),
            .init(path: fur.strokedPath(StrokeStyle(lineWidth: 1)), ink: 5, coverage: 0.55)
        ])
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 90, y: 39))
            p.addCurve(to: .init(x: 143, y: 70), control1: .init(x: 116, y: 38), control2: .init(x: 136, y: 48))
            p.addQuadCurve(to: .init(x: 136, y: 84), control: .init(x: 151, y: 83))
            p.addLine(to: .init(x: 87, y: 84))
            p.addQuadCurve(to: .init(x: 77, y: 55), control: .init(x: 74, y: 78))
            p.closeSubpath()
        }
    }

    private static var shoulder: Path {
        Path { p in
            p.move(to: .init(x: 89, y: 39))
            p.addCurve(to: .init(x: 127, y: 66), control1: .init(x: 111, y: 38), control2: .init(x: 123, y: 50))
            p.addQuadCurve(to: .init(x: 100, y: 78), control: .init(x: 109, y: 62))
            p.addLine(to: .init(x: 83, y: 71)); p.addLine(to: .init(x: 78, y: 51)); p.closeSubpath()
        }
    }

    private static var shoulderShade: Path {
        Path { p in
            p.move(to: .init(x: 99, y: 46)); p.addQuadCurve(to: .init(x: 127, y: 66), control: .init(x: 120, y: 49))
            p.addQuadCurve(to: .init(x: 107, y: 70), control: .init(x: 113, y: 64))
            p.addQuadCurve(to: .init(x: 99, y: 46), control: .init(x: 112, y: 56)); p.closeSubpath()
        }
    }

    private static var legs: Path {
        Path { p in
            p.move(to: .init(x: 81, y: 65)); p.addLine(to: .init(x: 89, y: 68))
            p.addLine(to: .init(x: 87, y: 83)); p.addLine(to: .init(x: 91, y: 86))
            p.addLine(to: .init(x: 77, y: 86)); p.addLine(to: .init(x: 80, y: 81)); p.closeSubpath()
            p.move(to: .init(x: 96, y: 64)); p.addLine(to: .init(x: 102, y: 66))
            p.addLine(to: .init(x: 101, y: 83)); p.addLine(to: .init(x: 106, y: 86))
            p.addLine(to: .init(x: 93, y: 86)); p.closeSubpath()
        }
    }

    private static var bib: Path {
        Path { p in
            p.move(to: .init(x: 77, y: 43)); p.addLine(to: .init(x: 97, y: 42))
            p.addQuadCurve(to: .init(x: 98, y: 65), control: .init(x: 104, y: 54))
            p.addLine(to: .init(x: 92, y: 61)); p.addLine(to: .init(x: 91, y: 73))
            p.addLine(to: .init(x: 84, y: 67)); p.addLine(to: .init(x: 80, y: 69))
            p.addQuadCurve(to: .init(x: 77, y: 43), control: .init(x: 72, y: 55)); p.closeSubpath()
        }
    }

    private static var bibShade: Path {
        Path { p in
            p.move(to: .init(x: 93, y: 46)); p.addQuadCurve(to: .init(x: 98, y: 65), control: .init(x: 102, y: 56))
            p.addLine(to: .init(x: 92, y: 61)); p.addLine(to: .init(x: 91, y: 70))
            p.addLine(to: .init(x: 86, y: 61)); p.closeSubpath()
        }
    }

    private static var tail: Path {
        Path { p in
            p.move(to: .init(x: 125, y: 64))
            p.addCurve(to: .init(x: 158, y: 66), control1: .init(x: 139, y: 57), control2: .init(x: 149, y: 60))
            p.addCurve(to: .init(x: 197, y: 70), control1: .init(x: 172, y: 75), control2: .init(x: 183, y: 76))
            p.addLine(to: .init(x: 189, y: 78)); p.addLine(to: .init(x: 193, y: 78))
            p.addCurve(to: .init(x: 152, y: 90), control1: .init(x: 181, y: 87), control2: .init(x: 166, y: 93))
            p.addCurve(to: .init(x: 117, y: 76), control1: .init(x: 125, y: 90), control2: .init(x: 113, y: 86))
            p.addQuadCurve(to: .init(x: 125, y: 64), control: .init(x: 115, y: 68)); p.closeSubpath()
        }
    }

    private static var tailShade: Path {
        Path { p in
            p.move(to: .init(x: 119, y: 76)); p.addCurve(to: .init(x: 182, y: 82), control1: .init(x: 131, y: 86), control2: .init(x: 165, y: 86))
            p.addQuadCurve(to: .init(x: 151, y: 90), control: .init(x: 169, y: 93))
            p.addQuadCurve(to: .init(x: 119, y: 76), control: .init(x: 117, y: 89)); p.closeSubpath()
        }
    }

    private static var tailTip: Path {
        Path { p in
            p.move(to: .init(x: 168, y: 72)); p.addQuadCurve(to: .init(x: 197, y: 70), control: .init(x: 187, y: 77))
            p.addLine(to: .init(x: 189, y: 78)); p.addLine(to: .init(x: 193, y: 78))
            p.addQuadCurve(to: .init(x: 163, y: 89), control: .init(x: 178, y: 88))
            p.addLine(to: .init(x: 170, y: 82)); p.addLine(to: .init(x: 163, y: 81))
            p.addLine(to: .init(x: 171, y: 77)); p.closeSubpath()
        }
    }

    private static var head: Path {
        Path { p in
            p.move(to: .init(x: 69, y: 30)); p.addLine(to: .init(x: 68, y: 10))
            p.addLine(to: .init(x: 82, y: 26)); p.addLine(to: .init(x: 92, y: 12))
            p.addLine(to: .init(x: 97, y: 34)); p.addLine(to: .init(x: 102, y: 42))
            p.addLine(to: .init(x: 95, y: 42)); p.addLine(to: .init(x: 97, y: 47))
            p.addQuadCurve(to: .init(x: 77, y: 51), control: .init(x: 87, y: 53))
            p.addLine(to: .init(x: 54, y: 43)); p.addLine(to: .init(x: 64, y: 37))
            p.closeSubpath()
        }
    }

    private static var ears: Path {
        Path { p in
            p.move(to: .init(x: 71, y: 17)); p.addLine(to: .init(x: 79, y: 28))
            p.addLine(to: .init(x: 72, y: 30)); p.closeSubpath()
            p.move(to: .init(x: 91, y: 19)); p.addLine(to: .init(x: 94, y: 34))
            p.addLine(to: .init(x: 85, y: 30)); p.closeSubpath()
        }
    }

    private static var earLight: Path {
        Path { p in
            p.move(to: .init(x: 89, y: 25)); p.addLine(to: .init(x: 92, y: 32))
            p.addLine(to: .init(x: 86, y: 30)); p.closeSubpath()
        }
    }

    private static var cheek: Path {
        Path { p in
            p.move(to: .init(x: 55, y: 43)); p.addQuadCurve(to: .init(x: 79, y: 40), control: .init(x: 67, y: 45))
            p.addLine(to: .init(x: 96, y: 38)); p.addLine(to: .init(x: 90, y: 44))
            p.addLine(to: .init(x: 96, y: 46)); p.addQuadCurve(to: .init(x: 77, y: 51), control: .init(x: 85, y: 53))
            p.closeSubpath()
        }
    }

    private static var brow: Path {
        Path { p in
            p.move(to: .init(x: 66, y: 36)); p.addQuadCurve(to: .init(x: 83, y: 32), control: .init(x: 75, y: 28))
            p.addLine(to: .init(x: 79, y: 39)); p.addLine(to: .init(x: 65, y: 40)); p.closeSubpath()
        }
    }

    private static var features: Path {
        Path { p in
            p.move(to: .init(x: 53, y: 42)); p.addLine(to: .init(x: 59, y: 41))
            p.addLine(to: .init(x: 57, y: 45)); p.closeSubpath()
            p.move(to: .init(x: 73, y: 36)); p.addLine(to: .init(x: 78, y: 35))
            p.addLine(to: .init(x: 76, y: 38)); p.addLine(to: .init(x: 74, y: 38)); p.closeSubpath()
        }
    }

    private static var fur: Path {
        Path { p in
            p.move(to: .init(x: 102, y: 44)); p.addQuadCurve(to: .init(x: 117, y: 52), control: .init(x: 112, y: 45))
            p.move(to: .init(x: 131, y: 66)); p.addQuadCurve(to: .init(x: 152, y: 70), control: .init(x: 143, y: 63))
        }
    }

    private static var grasses: Path {
        Path { p in
            p.move(to: .init(x: 30, y: 86)); p.addQuadCurve(to: .init(x: 22, y: 60), control: .init(x: 30, y: 70))
            p.addQuadCurve(to: .init(x: 33, y: 77), control: .init(x: 32, y: 62))
            p.addLine(to: .init(x: 38, y: 52)); p.addLine(to: .init(x: 38, y: 80))
            p.addQuadCurve(to: .init(x: 48, y: 66), control: .init(x: 39, y: 69))
            p.addLine(to: .init(x: 42, y: 87)); p.closeSubpath()
        }
    }
}
