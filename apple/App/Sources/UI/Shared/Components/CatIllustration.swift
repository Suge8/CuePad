import SwiftUI

/// 窗台上向右伸懒腰的猫：后腰抬高、前爪远伸，长尾逆着背线向左上弯起。
nonisolated enum CatIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xEAC7B3, 0xBD8D97, 0x442B49, 0x77536E, 0xD69A83, 0xFAE4BD], layers: [
            .init(path: window, ink: 5, coverage: 0.55),
            .init(path: mullion, ink: 1, coverage: 0.65),
            .init(path: sill, ink: 1),
            .init(path: Path(ellipseIn: CGRect(x: 45, y: 81, width: 150, height: 7)), ink: 3, coverage: 0.35),
            .init(path: tail, ink: 2),
            .init(path: tailLight, ink: 3, coverage: 0.7),
            .init(path: farLegs, ink: 3),
            .init(path: body, ink: 2),
            .init(path: backLight, ink: 3),
            .init(path: flank, ink: 4, coverage: 0.6),
            .init(path: shoulderLight, ink: 3, coverage: 0.65),
            .init(path: paws, ink: 5),
            .init(path: head, ink: 2),
            .init(path: faceLight, ink: 3),
            .init(path: ears, ink: 4),
            .init(path: muzzle, ink: 5),
            .init(path: eye.strokedPath(StrokeStyle(lineWidth: 1.2, lineCap: .round)), ink: 5),
            .init(path: nose, ink: 4),
            .init(path: whiskers.strokedPath(StrokeStyle(lineWidth: 0.7)), ink: 5, coverage: 0.8),
            .init(path: stripes, ink: 2, coverage: 0.8)
        ])
    }

    private static var window: Path {
        Path { p in
            p.move(to: .init(x: 16, y: 0)); p.addLine(to: .init(x: 88, y: 0))
            p.addLine(to: .init(x: 66, y: 77)); p.addLine(to: .init(x: 16, y: 77)); p.closeSubpath()
        }
    }

    private static var mullion: Path {
        Path { p in
            p.addRect(CGRect(x: 16, y: 0, width: 3, height: 78))
            p.addRect(CGRect(x: 19, y: 25, width: 60, height: 2))
        }
    }

    private static var sill: Path {
        Path { p in
            p.move(to: .init(x: 10, y: 85)); p.addLine(to: .init(x: 207, y: 85))
            p.addLine(to: .init(x: 199, y: 90)); p.addLine(to: .init(x: 10, y: 90)); p.closeSubpath()
        }
    }

    private static var tail: Path {
        Path { p in
            p.move(to: .init(x: 76, y: 42))
            p.addCurve(to: .init(x: 49, y: 22), control1: .init(x: 61, y: 42), control2: .init(x: 48, y: 35))
            p.addCurve(to: .init(x: 60, y: 13), control1: .init(x: 47, y: 11), control2: .init(x: 56, y: 6))
            p.addQuadCurve(to: .init(x: 58, y: 19), control: .init(x: 63, y: 18))
            p.addQuadCurve(to: .init(x: 56, y: 25), control: .init(x: 52, y: 15))
            p.addCurve(to: .init(x: 81, y: 34), control1: .init(x: 61, y: 34), control2: .init(x: 72, y: 30))
            p.closeSubpath()
        }
    }

    private static var tailLight: Path {
        Path { p in
            p.move(to: .init(x: 52, y: 15)); p.addQuadCurve(to: .init(x: 55, y: 30), control: .init(x: 49, y: 25))
            p.addQuadCurve(to: .init(x: 76, y: 39), control: .init(x: 64, y: 39))
            p.addLine(to: .init(x: 77, y: 36)); p.addQuadCurve(to: .init(x: 52, y: 15), control: .init(x: 51, y: 35))
            p.closeSubpath()
        }
    }

    private static var farLegs: Path {
        Path { p in
            p.move(to: .init(x: 89, y: 49)); p.addLine(to: .init(x: 99, y: 57))
            p.addLine(to: .init(x: 86, y: 78)); p.addQuadCurve(to: .init(x: 89, y: 82), control: .init(x: 94, y: 79))
            p.addLine(to: .init(x: 75, y: 82)); p.addLine(to: .init(x: 79, y: 75)); p.closeSubpath()
            p.move(to: .init(x: 126, y: 64)); p.addLine(to: .init(x: 143, y: 67))
            p.addLine(to: .init(x: 178, y: 77)); p.addQuadCurve(to: .init(x: 185, y: 81), control: .init(x: 185, y: 77))
            p.addLine(to: .init(x: 172, y: 82)); p.addLine(to: .init(x: 137, y: 75)); p.closeSubpath()
        }
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 65, y: 48))
            p.addCurve(to: .init(x: 97, y: 34), control1: .init(x: 64, y: 28), control2: .init(x: 85, y: 26))
            p.addCurve(to: .init(x: 135, y: 56), control1: .init(x: 110, y: 44), control2: .init(x: 120, y: 53))
            p.addLine(to: .init(x: 150, y: 61)); p.addLine(to: .init(x: 153, y: 73))
            p.addLine(to: .init(x: 178, y: 80)); p.addQuadCurve(to: .init(x: 183, y: 85), control: .init(x: 185, y: 80))
            p.addLine(to: .init(x: 168, y: 85)); p.addLine(to: .init(x: 139, y: 78))
            p.addQuadCurve(to: .init(x: 116, y: 66), control: .init(x: 124, y: 75))
            p.addQuadCurve(to: .init(x: 89, y: 56), control: .init(x: 101, y: 56))
            p.addLine(to: .init(x: 76, y: 78)); p.addQuadCurve(to: .init(x: 80, y: 85), control: .init(x: 85, y: 80))
            p.addLine(to: .init(x: 62, y: 85)); p.addLine(to: .init(x: 66, y: 76))
            p.addQuadCurve(to: .init(x: 65, y: 48), control: .init(x: 63, y: 63)); p.closeSubpath()
        }
    }

    private static var backLight: Path {
        Path { p in
            p.move(to: .init(x: 68, y: 43))
            p.addCurve(to: .init(x: 97, y: 36), control1: .init(x: 72, y: 29), control2: .init(x: 87, y: 30))
            p.addQuadCurve(to: .init(x: 136, y: 59), control: .init(x: 117, y: 54))
            p.addQuadCurve(to: .init(x: 95, y: 47), control: .init(x: 109, y: 56))
            p.addQuadCurve(to: .init(x: 68, y: 43), control: .init(x: 75, y: 39)); p.closeSubpath()
        }
    }

    private static var flank: Path {
        Path { p in
            p.move(to: .init(x: 70, y: 42)); p.addQuadCurve(to: .init(x: 87, y: 43), control: .init(x: 79, y: 35))
            p.addQuadCurve(to: .init(x: 74, y: 66), control: .init(x: 91, y: 52))
            p.addLine(to: .init(x: 69, y: 75)); p.addQuadCurve(to: .init(x: 70, y: 42), control: .init(x: 73, y: 57))
            p.closeSubpath()
        }
    }

    private static var shoulderLight: Path {
        Path { p in
            p.move(to: .init(x: 111, y: 58)); p.addQuadCurve(to: .init(x: 146, y: 64), control: .init(x: 134, y: 61))
            p.addLine(to: .init(x: 145, y: 74)); p.addLine(to: .init(x: 172, y: 82))
            p.addLine(to: .init(x: 139, y: 75)); p.addQuadCurve(to: .init(x: 111, y: 58), control: .init(x: 121, y: 69))
            p.closeSubpath()
        }
    }

    private static var paws: Path {
        Path { p in
            p.move(to: .init(x: 65, y: 80)); p.addLine(to: .init(x: 77, y: 80))
            p.addQuadCurve(to: .init(x: 80, y: 85), control: .init(x: 83, y: 82))
            p.addLine(to: .init(x: 62, y: 85)); p.closeSubpath()
            p.move(to: .init(x: 171, y: 79)); p.addLine(to: .init(x: 178, y: 80))
            p.addQuadCurve(to: .init(x: 183, y: 85), control: .init(x: 185, y: 80))
            p.addLine(to: .init(x: 168, y: 85)); p.closeSubpath()
        }
    }

    private static var head: Path {
        Path { p in
            p.move(to: .init(x: 139, y: 61)); p.addLine(to: .init(x: 140, y: 47))
            p.addLine(to: .init(x: 150, y: 56)); p.addLine(to: .init(x: 162, y: 51))
            p.addLine(to: .init(x: 161, y: 64)); p.addQuadCurve(to: .init(x: 168, y: 70), control: .init(x: 168, y: 66))
            p.addQuadCurve(to: .init(x: 154, y: 78), control: .init(x: 166, y: 78))
            p.addQuadCurve(to: .init(x: 139, y: 61), control: .init(x: 140, y: 78)); p.closeSubpath()
        }
    }

    private static var faceLight: Path {
        Path { p in
            p.move(to: .init(x: 150, y: 59)); p.addLine(to: .init(x: 159, y: 57))
            p.addLine(to: .init(x: 159, y: 65)); p.addQuadCurve(to: .init(x: 165, y: 71), control: .init(x: 164, y: 67))
            p.addLine(to: .init(x: 153, y: 74)); p.addLine(to: .init(x: 146, y: 69)); p.closeSubpath()
        }
    }

    private static var ears: Path {
        Path { p in
            p.move(to: .init(x: 142, y: 52)); p.addLine(to: .init(x: 148, y: 58))
            p.addLine(to: .init(x: 143, y: 60)); p.closeSubpath()
            p.move(to: .init(x: 155, y: 58)); p.addLine(to: .init(x: 160, y: 55))
            p.addLine(to: .init(x: 159, y: 62)); p.closeSubpath()
        }
    }

    private static var muzzle: Path {
        Path { p in
            p.move(to: .init(x: 155, y: 70)); p.addQuadCurve(to: .init(x: 168, y: 70), control: .init(x: 163, y: 67))
            p.addQuadCurve(to: .init(x: 153, y: 77), control: .init(x: 166, y: 78))
            p.addLine(to: .init(x: 150, y: 74)); p.closeSubpath()
        }
    }

    private static var eye: Path {
        Path { p in
            p.move(to: .init(x: 150, y: 65)); p.addQuadCurve(to: .init(x: 156, y: 66), control: .init(x: 152, y: 68))
        }
    }

    private static var nose: Path {
        Path { p in
            p.move(to: .init(x: 164, y: 69)); p.addLine(to: .init(x: 169, y: 69))
            p.addLine(to: .init(x: 166, y: 72)); p.closeSubpath()
        }
    }

    private static var whiskers: Path {
        Path { p in
            p.move(to: .init(x: 160, y: 73)); p.addLine(to: .init(x: 177, y: 68))
            p.move(to: .init(x: 160, y: 74)); p.addLine(to: .init(x: 178, y: 74))
        }
    }

    private static var stripes: Path {
        Path { p in
            p.move(to: .init(x: 80, y: 32)); p.addLine(to: .init(x: 84, y: 32))
            p.addLine(to: .init(x: 84, y: 43)); p.closeSubpath()
            p.move(to: .init(x: 91, y: 34)); p.addLine(to: .init(x: 95, y: 35))
            p.addLine(to: .init(x: 98, y: 47)); p.closeSubpath()
            p.move(to: .init(x: 105, y: 44)); p.addLine(to: .init(x: 109, y: 47))
            p.addLine(to: .init(x: 109, y: 54)); p.closeSubpath()
        }
    }
}
