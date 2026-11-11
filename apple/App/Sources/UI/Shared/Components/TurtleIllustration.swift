import SwiftUI

/// 俯看浅海里斜向右上游的海龟：盾片拼成拱壳，前鳍长、后鳍短，暖沙色只照亮壳沿与皮肤。
nonisolated enum TurtleIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0x9BCBC1, 0x67ACA6, 0x294F46, 0x597E58, 0xE4CF98, 0xCDE5CF], layers: [
            .init(path: shallows, ink: 5, coverage: 0.4),
            .init(path: waterLight.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round)), ink: 5, coverage: 0.7),
            .init(path: seaGrass, ink: 1),
            .init(path: farFlippers, ink: 2),
            .init(path: farFlipperLight, ink: 3),
            .init(path: tail, ink: 3),
            .init(path: head, ink: 3),
            .init(path: headLight, ink: 4, coverage: 0.7),
            .init(path: nearFlippers, ink: 2),
            .init(path: nearFlipperLight, ink: 4),
            .init(path: flipperShade, ink: 3, coverage: 0.7),
            .init(path: shell, ink: 2),
            .init(path: shellRim, ink: 4),
            .init(path: shellCrown, ink: 3),
            .init(path: shellLight, ink: 4, coverage: 0.4),
            .init(path: shellShade, ink: 2, coverage: 0.35),
            .init(path: scuteSeams.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)), ink: 2),
            .init(path: scuteGlints.strokedPath(StrokeStyle(lineWidth: 0.85, lineCap: .round)), ink: 4, coverage: 0.8),
            .init(path: skinMarks.strokedPath(StrokeStyle(lineWidth: 0.8, lineCap: .round)), ink: 3),
            .init(path: face, ink: 2)
        ])
    }

    private static var shallows: Path {
        Path { p in
            p.move(to: .init(x: 142, y: 0)); p.addLine(to: .init(x: 220, y: 0))
            p.addLine(to: .init(x: 220, y: 23))
            p.addCurve(to: .init(x: 142, y: 0), control1: .init(x: 184, y: 35), control2: .init(x: 178, y: 7))
            p.closeSubpath()
        }
    }

    private static var waterLight: Path {
        Path { p in
            p.move(to: .init(x: 22, y: 29)); p.addQuadCurve(to: .init(x: 48, y: 25), control: .init(x: 37, y: 31))
            p.addQuadCurve(to: .init(x: 65, y: 27), control: .init(x: 54, y: 21))
            p.move(to: .init(x: 31, y: 36)); p.addQuadCurve(to: .init(x: 43, y: 34), control: .init(x: 38, y: 38))
            p.move(to: .init(x: 171, y: 83)); p.addQuadCurve(to: .init(x: 195, y: 80), control: .init(x: 181, y: 77))
            p.addQuadCurve(to: .init(x: 212, y: 77), control: .init(x: 204, y: 84))
        }
    }

    private static var farFlippers: Path {
        Path { p in
            p.move(to: .init(x: 116, y: 36))
            p.addCurve(to: .init(x: 108, y: 8), control1: .init(x: 106, y: 29), control2: .init(x: 104, y: 17))
            p.addCurve(to: .init(x: 128, y: 23), control1: .init(x: 119, y: 10), control2: .init(x: 120, y: 20))
            p.addQuadCurve(to: .init(x: 133, y: 36), control: .init(x: 139, y: 30)); p.closeSubpath()
            p.move(to: .init(x: 87, y: 51))
            p.addQuadCurve(to: .init(x: 63, y: 43), control: .init(x: 71, y: 53))
            p.addQuadCurve(to: .init(x: 75, y: 38), control: .init(x: 63, y: 37))
            p.addQuadCurve(to: .init(x: 94, y: 44), control: .init(x: 87, y: 37)); p.closeSubpath()
        }
    }

    private static var farFlipperLight: Path {
        Path { p in
            p.move(to: .init(x: 109, y: 12))
            p.addQuadCurve(to: .init(x: 126, y: 27), control: .init(x: 116, y: 15))
            p.addLine(to: .init(x: 127, y: 34))
            p.addQuadCurve(to: .init(x: 109, y: 12), control: .init(x: 112, y: 28)); p.closeSubpath()
            p.move(to: .init(x: 67, y: 41)); p.addQuadCurve(to: .init(x: 89, y: 44), control: .init(x: 77, y: 38))
            p.addLine(to: .init(x: 82, y: 47)); p.closeSubpath()
        }
    }

    private static var tail: Path {
        Path { p in
            p.move(to: .init(x: 84, y: 70)); p.addQuadCurve(to: .init(x: 69, y: 80), control: .init(x: 77, y: 79))
            p.addLine(to: .init(x: 78, y: 64)); p.closeSubpath()
        }
    }

    private static var head: Path {
        Path { p in
            p.move(to: .init(x: 135, y: 33))
            p.addQuadCurve(to: .init(x: 145, y: 23), control: .init(x: 144, y: 30))
            p.addCurve(to: .init(x: 158, y: 20), control1: .init(x: 147, y: 17), control2: .init(x: 154, y: 16))
            p.addQuadCurve(to: .init(x: 163, y: 27), control: .init(x: 163, y: 22))
            p.addQuadCurve(to: .init(x: 157, y: 35), control: .init(x: 163, y: 32))
            p.addQuadCurve(to: .init(x: 147, y: 37), control: .init(x: 153, y: 36))
            p.addLine(to: .init(x: 142, y: 43)); p.closeSubpath()
        }
    }

    private static var headLight: Path {
        Path { p in
            p.move(to: .init(x: 140, y: 33)); p.addLine(to: .init(x: 148, y: 24))
            p.addQuadCurve(to: .init(x: 158, y: 22), control: .init(x: 151, y: 18))
            p.addQuadCurve(to: .init(x: 157, y: 30), control: .init(x: 164, y: 26))
            p.addQuadCurve(to: .init(x: 149, y: 32), control: .init(x: 153, y: 28))
            p.addLine(to: .init(x: 144, y: 38)); p.closeSubpath()
        }
    }

    private static var nearFlippers: Path {
        Path { p in
            p.move(to: .init(x: 137, y: 43))
            p.addCurve(to: .init(x: 165, y: 54), control1: .init(x: 150, y: 42), control2: .init(x: 158, y: 43))
            p.addQuadCurve(to: .init(x: 182, y: 73), control: .init(x: 172, y: 67))
            p.addCurve(to: .init(x: 153, y: 67), control1: .init(x: 176, y: 76), control2: .init(x: 161, y: 74))
            p.addQuadCurve(to: .init(x: 134, y: 55), control: .init(x: 143, y: 59)); p.closeSubpath()
            p.move(to: .init(x: 96, y: 70))
            p.addQuadCurve(to: .init(x: 100, y: 85), control: .init(x: 103, y: 79))
            p.addQuadCurve(to: .init(x: 78, y: 94), control: .init(x: 90, y: 94))
            p.addQuadCurve(to: .init(x: 82, y: 80), control: .init(x: 77, y: 87))
            p.addLine(to: .init(x: 85, y: 69)); p.closeSubpath()
        }
    }

    private static var nearFlipperLight: Path {
        Path { p in
            p.move(to: .init(x: 143, y: 47))
            p.addQuadCurve(to: .init(x: 164, y: 56), control: .init(x: 156, y: 47))
            p.addLine(to: .init(x: 178, y: 71))
            p.addQuadCurve(to: .init(x: 153, y: 62), control: .init(x: 164, y: 70))
            p.addLine(to: .init(x: 140, y: 53)); p.closeSubpath()
            p.move(to: .init(x: 90, y: 75)); p.addQuadCurve(to: .init(x: 96, y: 84), control: .init(x: 98, y: 80))
            p.addQuadCurve(to: .init(x: 81, y: 91), control: .init(x: 88, y: 90))
            p.addQuadCurve(to: .init(x: 90, y: 75), control: .init(x: 84, y: 81)); p.closeSubpath()
        }
    }

    private static var flipperShade: Path {
        Path { p in
            p.move(to: .init(x: 144, y: 50)); p.addQuadCurve(to: .init(x: 163, y: 58), control: .init(x: 155, y: 51))
            p.addLine(to: .init(x: 175, y: 70)); p.addQuadCurve(to: .init(x: 144, y: 50), control: .init(x: 155, y: 64)); p.closeSubpath()
            p.move(to: .init(x: 89, y: 77)); p.addLine(to: .init(x: 94, y: 83))
            p.addLine(to: .init(x: 82, y: 90)); p.closeSubpath()
        }
    }

    private static var shell: Path {
        Path { p in
            p.move(to: .init(x: 80, y: 72))
            p.addCurve(to: .init(x: 85, y: 43), control1: .init(x: 72, y: 64), control2: .init(x: 75, y: 51))
            p.addCurve(to: .init(x: 117, y: 28), control1: .init(x: 92, y: 34), control2: .init(x: 108, y: 28))
            p.addCurve(to: .init(x: 140, y: 33), control1: .init(x: 127, y: 26), control2: .init(x: 137, y: 28))
            p.addCurve(to: .init(x: 144, y: 55), control1: .init(x: 149, y: 38), control2: .init(x: 150, y: 47))
            p.addCurve(to: .init(x: 112, y: 76), control1: .init(x: 137, y: 67), control2: .init(x: 125, y: 73))
            p.addQuadCurve(to: .init(x: 80, y: 72), control: .init(x: 91, y: 83)); p.closeSubpath()
        }
    }

    private static var shellRim: Path {
        Path { p in
            p.move(to: .init(x: 82, y: 69))
            p.addCurve(to: .init(x: 88, y: 44), control1: .init(x: 77, y: 61), control2: .init(x: 81, y: 51))
            p.addCurve(to: .init(x: 124, y: 30), control1: .init(x: 96, y: 35), control2: .init(x: 114, y: 28))
            p.addQuadCurve(to: .init(x: 141, y: 37), control: .init(x: 136, y: 29))
            p.addCurve(to: .init(x: 137, y: 58), control1: .init(x: 148, y: 42), control2: .init(x: 143, y: 51))
            p.addQuadCurve(to: .init(x: 109, y: 73), control: .init(x: 127, y: 70))
            p.addQuadCurve(to: .init(x: 82, y: 69), control: .init(x: 91, y: 79)); p.closeSubpath()
        }
    }

    private static var shellCrown: Path {
        Path { p in
            p.move(to: .init(x: 85, y: 65))
            p.addCurve(to: .init(x: 92, y: 43), control1: .init(x: 80, y: 57), control2: .init(x: 86, y: 48))
            p.addQuadCurve(to: .init(x: 124, y: 32), control: .init(x: 108, y: 30))
            p.addQuadCurve(to: .init(x: 139, y: 39), control: .init(x: 135, y: 31))
            p.addQuadCurve(to: .init(x: 132, y: 58), control: .init(x: 146, y: 48))
            p.addQuadCurve(to: .init(x: 106, y: 70), control: .init(x: 119, y: 70))
            p.addQuadCurve(to: .init(x: 85, y: 65), control: .init(x: 91, y: 76)); p.closeSubpath()
        }
    }

    private static var shellLight: Path {
        Path { p in
            p.move(to: .init(x: 86, y: 56))
            p.addQuadCurve(to: .init(x: 120, y: 33), control: .init(x: 92, y: 34))
            p.addQuadCurve(to: .init(x: 134, y: 36), control: .init(x: 130, y: 31))
            p.addLine(to: .init(x: 113, y: 43)); p.addLine(to: .init(x: 104, y: 56))
            p.addLine(to: .init(x: 89, y: 65)); p.closeSubpath()
        }
    }

    private static var shellShade: Path {
        Path { p in
            p.move(to: .init(x: 138, y: 41))
            p.addQuadCurve(to: .init(x: 130, y: 59), control: .init(x: 143, y: 49))
            p.addQuadCurve(to: .init(x: 92, y: 70), control: .init(x: 108, y: 77))
            p.addLine(to: .init(x: 111, y: 59)); p.addLine(to: .init(x: 128, y: 52)); p.closeSubpath()
        }
    }

    private static var scuteSeams: Path {
        Path { p in
            p.move(to: .init(x: 85, y: 65)); p.addLine(to: .init(x: 92, y: 55))
            p.addLine(to: .init(x: 105, y: 56)); p.addLine(to: .init(x: 111, y: 66)); p.addLine(to: .init(x: 108, y: 72))
            p.move(to: .init(x: 92, y: 55)); p.addLine(to: .init(x: 94, y: 44)); p.addLine(to: .init(x: 89, y: 40))
            p.move(to: .init(x: 94, y: 44)); p.addLine(to: .init(x: 110, y: 40))
            p.addLine(to: .init(x: 122, y: 47)); p.addLine(to: .init(x: 120, y: 59)); p.addLine(to: .init(x: 111, y: 66))
            p.move(to: .init(x: 105, y: 56)); p.addLine(to: .init(x: 110, y: 40)); p.addLine(to: .init(x: 111, y: 32))
            p.move(to: .init(x: 122, y: 47)); p.addLine(to: .init(x: 133, y: 38)); p.addLine(to: .init(x: 131, y: 32))
            p.move(to: .init(x: 133, y: 38)); p.addLine(to: .init(x: 142, y: 42))
            p.move(to: .init(x: 120, y: 59)); p.addLine(to: .init(x: 131, y: 62))
            p.move(to: .init(x: 83, y: 58)); p.addLine(to: .init(x: 78, y: 58))
            p.move(to: .init(x: 94, y: 72)); p.addLine(to: .init(x: 94, y: 77))
        }
    }

    private static var scuteGlints: Path {
        Path { p in
            p.move(to: .init(x: 98, y: 46)); p.addLine(to: .init(x: 106, y: 44)); p.addLine(to: .init(x: 103, y: 51))
            p.move(to: .init(x: 114, y: 42)); p.addLine(to: .init(x: 120, y: 45))
            p.move(to: .init(x: 115, y: 37)); p.addQuadCurve(to: .init(x: 128, y: 35), control: .init(x: 123, y: 34))
            p.move(to: .init(x: 91, y: 62)); p.addLine(to: .init(x: 95, y: 59)); p.addLine(to: .init(x: 102, y: 60))
        }
    }

    private static var skinMarks: Path {
        Path { p in
            p.move(to: .init(x: 151, y: 24)); p.addLine(to: .init(x: 154, y: 22)); p.addLine(to: .init(x: 157, y: 24))
            p.move(to: .init(x: 147, y: 30)); p.addLine(to: .init(x: 151, y: 28)); p.addLine(to: .init(x: 153, y: 30))
            p.move(to: .init(x: 153, y: 53)); p.addLine(to: .init(x: 152, y: 57))
            p.move(to: .init(x: 158, y: 56)); p.addLine(to: .init(x: 158, y: 61))
            p.move(to: .init(x: 163, y: 60)); p.addLine(to: .init(x: 164, y: 65))
            p.move(to: .init(x: 88, y: 84)); p.addLine(to: .init(x: 91, y: 86))
        }
    }

    private static var face: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 157, y: 26, width: 1.9, height: 1.9))
            p.move(to: .init(x: 158, y: 32)); p.addLine(to: .init(x: 162, y: 29))
            p.addLine(to: .init(x: 160, y: 32.5)); p.closeSubpath()
        }
    }

    private static var seaGrass: Path {
        Path { p in
            p.move(to: .init(x: 25, y: 100))
            p.addQuadCurve(to: .init(x: 19, y: 74), control: .init(x: 15, y: 88))
            p.addQuadCurve(to: .init(x: 29, y: 100), control: .init(x: 23, y: 91)); p.closeSubpath()
            p.move(to: .init(x: 31, y: 100))
            p.addQuadCurve(to: .init(x: 40, y: 69), control: .init(x: 32, y: 79))
            p.addQuadCurve(to: .init(x: 35, y: 100), control: .init(x: 40, y: 90)); p.closeSubpath()
            p.move(to: .init(x: 39, y: 100)); p.addQuadCurve(to: .init(x: 53, y: 86), control: .init(x: 43, y: 88))
            p.addQuadCurve(to: .init(x: 43, y: 100), control: .init(x: 46, y: 95)); p.closeSubpath()
        }
    }
}
