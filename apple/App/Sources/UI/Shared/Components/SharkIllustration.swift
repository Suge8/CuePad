import SwiftUI

/// 浅水里向右穿行的鲨鱼：尖吻、立起的背鳍、长胸鳍和不对称尾；珊瑚留在远处。
nonisolated enum SharkIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xD7E7E8, 0xA9CBD4, 0x355766, 0x7B9BAA, 0xF3EFDE, 0xCE836C], layers: [
            .init(path: light, ink: 4, coverage: 0.55),
            .init(path: seaFloor, ink: 1, coverage: 0.40),
            .init(path: coral.strokedPath(StrokeStyle(lineWidth: 1.4, lineCap: .round)), ink: 5),
            .init(path: tail, ink: 2),
            .init(path: tailLight, ink: 3),
            .init(path: dorsal, ink: 2),
            .init(path: rearFin, ink: 2),
            .init(path: body, ink: 3),
            .init(path: backShade, ink: 2, coverage: 0.32),
            .init(path: belly, ink: 4),
            .init(path: bellyShade, ink: 1, coverage: 0.48),
            .init(path: pectoral, ink: 2),
            .init(path: finLight, ink: 3, coverage: 0.65),
            .init(path: gills.strokedPath(StrokeStyle(lineWidth: 0.8)), ink: 2),
            .init(path: mouth.strokedPath(StrokeStyle(lineWidth: 0.75)), ink: 2),
            .init(path: Path(ellipseIn: CGRect(x: 169, y: 50, width: 2, height: 2)), ink: 2),
            .init(path: distantFish, ink: 1)
        ])
    }

    private static var light: Path {
        Path { p in
            p.move(to: .init(x: 20, y: 0)); p.addLine(to: .init(x: 72, y: 0))
            p.addLine(to: .init(x: 127, y: 100)); p.addLine(to: .init(x: 96, y: 100)); p.closeSubpath()
        }
    }

    private static var seaFloor: Path {
        Path { p in
            p.move(to: .init(x: 0, y: 89)); p.addCurve(to: .init(x: 220, y: 84), control1: .init(x: 87, y: 103), control2: .init(x: 155, y: 73))
            p.addLine(to: .init(x: 220, y: 100)); p.addLine(to: .init(x: 0, y: 100)); p.closeSubpath()
        }
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 51, y: 49))
            p.addCurve(to: .init(x: 143, y: 42), control1: .init(x: 80, y: 36), control2: .init(x: 119, y: 33))
            p.addQuadCurve(to: .init(x: 190, y: 55), control: .init(x: 169, y: 45))
            p.addQuadCurve(to: .init(x: 150, y: 65), control: .init(x: 175, y: 59))
            p.addCurve(to: .init(x: 57, y: 55), control1: .init(x: 124, y: 72), control2: .init(x: 83, y: 65))
            p.closeSubpath()
        }
    }

    private static var tail: Path {
        Path { p in
            p.move(to: .init(x: 59, y: 48)); p.addQuadCurve(to: .init(x: 33, y: 17), control: .init(x: 43, y: 30))
            p.addQuadCurve(to: .init(x: 40, y: 46), control: .init(x: 32, y: 36))
            p.addQuadCurve(to: .init(x: 24, y: 69), control: .init(x: 32, y: 58))
            p.addQuadCurve(to: .init(x: 58, y: 55), control: .init(x: 47, y: 65)); p.closeSubpath()
        }
    }

    private static var tailLight: Path {
        Path { p in
            p.move(to: .init(x: 36, y: 24)); p.addQuadCurve(to: .init(x: 59, y: 50), control: .init(x: 48, y: 36))
            p.addLine(to: .init(x: 43, y: 49)); p.closeSubpath()
        }
    }

    private static var dorsal: Path {
        Path { p in
            p.move(to: .init(x: 98, y: 39)); p.addQuadCurve(to: .init(x: 123, y: 13), control: .init(x: 114, y: 24))
            p.addQuadCurve(to: .init(x: 134, y: 42), control: .init(x: 121, y: 31)); p.closeSubpath()
        }
    }

    private static var rearFin: Path {
        Path { p in
            p.move(to: .init(x: 78, y: 58)); p.addLine(to: .init(x: 75, y: 74))
            p.addLine(to: .init(x: 99, y: 63)); p.closeSubpath()
        }
    }

    private static var backShade: Path {
        Path { p in
            p.move(to: .init(x: 59, y: 47)); p.addQuadCurve(to: .init(x: 148, y: 44), control: .init(x: 108, y: 29))
            p.addQuadCurve(to: .init(x: 59, y: 51), control: .init(x: 108, y: 41)); p.closeSubpath()
        }
    }

    private static var belly: Path {
        Path { p in
            p.move(to: .init(x: 62, y: 55)); p.addQuadCurve(to: .init(x: 186, y: 56), control: .init(x: 128, y: 64))
            p.addQuadCurve(to: .init(x: 150, y: 65), control: .init(x: 170, y: 60))
            p.addQuadCurve(to: .init(x: 62, y: 55), control: .init(x: 109, y: 73)); p.closeSubpath()
        }
    }

    private static var bellyShade: Path {
        Path { p in
            p.move(to: .init(x: 73, y: 59)); p.addQuadCurve(to: .init(x: 156, y: 62), control: .init(x: 114, y: 69))
            p.addQuadCurve(to: .init(x: 73, y: 59), control: .init(x: 118, y: 75)); p.closeSubpath()
        }
    }

    private static var pectoral: Path {
        Path { p in
            p.move(to: .init(x: 125, y: 55)); p.addQuadCurve(to: .init(x: 96, y: 86), control: .init(x: 115, y: 75))
            p.addQuadCurve(to: .init(x: 140, y: 61), control: .init(x: 119, y: 83)); p.closeSubpath()
        }
    }

    private static var finLight: Path {
        Path { p in
            p.move(to: .init(x: 129, y: 59)); p.addLine(to: .init(x: 103, y: 82))
            p.addQuadCurve(to: .init(x: 138, y: 62), control: .init(x: 121, y: 76)); p.closeSubpath()
        }
    }

    private static var gills: Path {
        Path { p in
            for x in stride(from: 146.0, through: 154.0, by: 4) {
                p.move(to: .init(x: x, y: 48)); p.addQuadCurve(to: .init(x: x - 2, y: 58), control: .init(x: x - 3, y: 53))
            }
        }
    }

    private static var mouth: Path {
        Path { p in
            p.move(to: .init(x: 181, y: 58)); p.addQuadCurve(to: .init(x: 165, y: 59), control: .init(x: 171, y: 62))
        }
    }

    private static var coral: Path {
        Path { p in
            p.move(to: .init(x: 197, y: 97)); p.addQuadCurve(to: .init(x: 194, y: 72), control: .init(x: 200, y: 83))
            p.move(to: .init(x: 198, y: 87)); p.addQuadCurve(to: .init(x: 208, y: 75), control: .init(x: 206, y: 85))
            p.move(to: .init(x: 197, y: 88)); p.addQuadCurve(to: .init(x: 185, y: 80), control: .init(x: 188, y: 91))
            p.move(to: .init(x: 195, y: 79)); p.addLine(to: .init(x: 188, y: 74))
            p.move(to: .init(x: 204, y: 82)); p.addLine(to: .init(x: 213, y: 81))
        }
    }

    private static var distantFish: Path {
        Path { p in
            for point in [CGPoint(x: 163, y: 22), .init(x: 179, y: 17), .init(x: 185, y: 29)] {
                p.move(to: point); p.addLine(to: .init(x: point.x + 5, y: point.y - 1))
                p.addLine(to: .init(x: point.x + 4, y: point.y + 2)); p.closeSubpath()
            }
        }
    }
}
