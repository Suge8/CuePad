import SwiftUI

/// 深海里缓慢游过的须鲸：宽额、浅腹、下垂胸鳍与分叉尾鳍；上方留水域。
nonisolated enum WhaleIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0x102D40, 0x1C4D61, 0x347E8D, 0x68ABA9, 0xE3DFC5, 0xA0C8BC], layers: [
            .init(path: water, ink: 1, coverage: 0.45),
            .init(path: Path(ellipseIn: CGRect(x: 35, y: 83, width: 149, height: 12)), ink: 1, coverage: 0.65),
            .init(path: tail, ink: 2),
            .init(path: dorsal, ink: 2),
            .init(path: body, ink: 2),
            .init(path: back, ink: 3, coverage: 0.55),
            .init(path: belly, ink: 4),
            .init(path: bellyShade, ink: 3, coverage: 0.42),
            .init(path: pleats.strokedPath(StrokeStyle(lineWidth: 0.65)), ink: 2, coverage: 0.7),
            .init(path: flipper, ink: 1),
            .init(path: flipperLight, ink: 3, coverage: 0.68),
            .init(path: Path(ellipseIn: CGRect(x: 48, y: 48, width: 2, height: 2)), ink: 0),
            .init(path: jaw.strokedPath(StrokeStyle(lineWidth: 0.8)), ink: 1),
            .init(path: weeds, ink: 2, coverage: 0.65),
            .init(path: plankton, ink: 5, coverage: 0.62)
        ])
    }

    private static var water: Path {
        Path { p in
            p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 158, y: 0))
            p.addCurve(to: .init(x: 0, y: 52), control1: .init(x: 117, y: 19), control2: .init(x: 47, y: 18))
            p.closeSubpath()
        }
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 39, y: 45))
            p.addCurve(to: .init(x: 91, y: 32), control1: .init(x: 43, y: 33), control2: .init(x: 72, y: 29))
            p.addCurve(to: .init(x: 145, y: 47), control1: .init(x: 116, y: 34), control2: .init(x: 129, y: 41))
            p.addCurve(to: .init(x: 177, y: 44), control1: .init(x: 160, y: 54), control2: .init(x: 169, y: 49))
            p.addLine(to: .init(x: 181, y: 49))
            p.addCurve(to: .init(x: 141, y: 66), control1: .init(x: 168, y: 63), control2: .init(x: 154, y: 66))
            p.addCurve(to: .init(x: 62, y: 79), control1: .init(x: 120, y: 79), control2: .init(x: 85, y: 84))
            p.addCurve(to: .init(x: 36, y: 59), control1: .init(x: 43, y: 76), control2: .init(x: 33, y: 70))
            p.addQuadCurve(to: .init(x: 39, y: 45), control: .init(x: 34, y: 51)); p.closeSubpath()
        }
    }

    private static var tail: Path {
        Path { p in
            p.move(to: .init(x: 168, y: 50))
            p.addQuadCurve(to: .init(x: 185, y: 26), control: .init(x: 175, y: 31))
            p.addQuadCurve(to: .init(x: 203, y: 23), control: .init(x: 195, y: 28))
            p.addQuadCurve(to: .init(x: 185, y: 43), control: .init(x: 200, y: 37))
            p.addQuadCurve(to: .init(x: 207, y: 53), control: .init(x: 194, y: 44))
            p.addQuadCurve(to: .init(x: 179, y: 52), control: .init(x: 190, y: 61))
            p.closeSubpath()
        }
    }

    private static var dorsal: Path {
        Path { p in
            p.move(to: .init(x: 123, y: 41)); p.addQuadCurve(to: .init(x: 133, y: 31), control: .init(x: 126, y: 32))
            p.addQuadCurve(to: .init(x: 146, y: 49), control: .init(x: 133, y: 43)); p.closeSubpath()
        }
    }

    private static var back: Path {
        Path { p in
            p.move(to: .init(x: 41, y: 44))
            p.addCurve(to: .init(x: 132, y: 46), control1: .init(x: 62, y: 24), control2: .init(x: 105, y: 35))
            p.addCurve(to: .init(x: 41, y: 49), control1: .init(x: 98, y: 40), control2: .init(x: 65, y: 39)); p.closeSubpath()
        }
    }

    private static var belly: Path {
        Path { p in
            p.move(to: .init(x: 37, y: 61))
            p.addCurve(to: .init(x: 139, y: 65), control1: .init(x: 67, y: 74), control2: .init(x: 108, y: 77))
            p.addCurve(to: .init(x: 62, y: 79), control1: .init(x: 120, y: 79), control2: .init(x: 85, y: 84))
            p.addQuadCurve(to: .init(x: 37, y: 61), control: .init(x: 37, y: 77)); p.closeSubpath()
        }
    }

    private static var bellyShade: Path {
        Path { p in
            p.move(to: .init(x: 41, y: 69)); p.addQuadCurve(to: .init(x: 129, y: 72), control: .init(x: 93, y: 86))
            p.addQuadCurve(to: .init(x: 62, y: 79), control: .init(x: 93, y: 88))
            p.addQuadCurve(to: .init(x: 41, y: 69), control: .init(x: 46, y: 76)); p.closeSubpath()
        }
    }

    private static var flipper: Path {
        Path { p in
            p.move(to: .init(x: 89, y: 62))
            p.addCurve(to: .init(x: 119, y: 93), control1: .init(x: 96, y: 71), control2: .init(x: 106, y: 91))
            p.addCurve(to: .init(x: 108, y: 66), control1: .init(x: 127, y: 96), control2: .init(x: 122, y: 79))
            p.closeSubpath()
        }
    }

    private static var flipperLight: Path {
        Path { p in
            p.move(to: .init(x: 95, y: 65)); p.addQuadCurve(to: .init(x: 119, y: 91), control: .init(x: 105, y: 83))
            p.addQuadCurve(to: .init(x: 108, y: 67), control: .init(x: 118, y: 80)); p.closeSubpath()
        }
    }

    private static var jaw: Path {
        Path { p in
            p.move(to: .init(x: 38, y: 58)); p.addQuadCurve(to: .init(x: 74, y: 65), control: .init(x: 57, y: 65))
        }
    }

    private static var pleats: Path {
        Path { p in
            for offset in stride(from: 0.0, through: 12.0, by: 4) {
                p.move(to: .init(x: 45 + offset, y: 66 + offset * 0.2))
                p.addQuadCurve(to: .init(x: 84 + offset, y: 79), control: .init(x: 56 + offset, y: 78))
            }
        }
    }

    private static var weeds: Path {
        Path { p in
            p.move(to: .init(x: 17, y: 100)); p.addQuadCurve(to: .init(x: 11, y: 76), control: .init(x: 2, y: 83))
            p.addQuadCurve(to: .init(x: 21, y: 100), control: .init(x: 19, y: 83)); p.closeSubpath()
            p.move(to: .init(x: 22, y: 100)); p.addQuadCurve(to: .init(x: 29, y: 67), control: .init(x: 31, y: 86))
            p.addQuadCurve(to: .init(x: 26, y: 100), control: .init(x: 40, y: 82)); p.closeSubpath()
        }
    }

    private static var plankton: Path {
        Path { p in
            for point in [CGPoint(x: 25, y: 32), .init(x: 81, y: 17), .init(x: 139, y: 21), .init(x: 160, y: 75), .init(x: 194, y: 81)] {
                p.addEllipse(in: CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5))
            }
        }
    }
}
