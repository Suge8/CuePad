import SwiftUI

/// 暖窗边的龟背竹：错落叶片有外缘裂口与内孔，叶柄汇入低处陶盆，左侧留透光空间。
nonisolated enum MonsteraIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0xEAE2CB, 0xCBC49B, 0x354F3C, 0x738850, 0xADBA74, 0xE8CF86], layers: [
            .init(path: windowLight, ink: 5, coverage: 0.32),
            .init(path: Path(ellipseIn: CGRect(x: 76, y: 91, width: 85, height: 8)), ink: 1, coverage: 0.55),
            .init(path: stems.strokedPath(StrokeStyle(lineWidth: 1.8, lineCap: .round)), ink: 2),
            .init(path: leftLeaf, ink: 2),
            .init(path: leftLight, ink: 3),
            .init(path: rightLeaf, ink: 3),
            .init(path: rightLight, ink: 4, coverage: 0.55),
            .init(path: youngLeaf, ink: 4),
            .init(path: youngShade, ink: 3, coverage: 0.52),
            .init(path: veins.strokedPath(StrokeStyle(lineWidth: 0.7)), ink: 4),
            .init(path: pot, ink: 1),
            .init(path: potLight, ink: 5, coverage: 0.68),
            .init(path: Path(ellipseIn: CGRect(x: 99, y: 77, width: 37, height: 5)), ink: 2),
            .init(path: rim.strokedPath(StrokeStyle(lineWidth: 1.5)), ink: 5)
        ])
    }

    private static var windowLight: Path {
        Path { p in
            p.move(to: .init(x: 30, y: 0)); p.addLine(to: .init(x: 77, y: 0))
            p.addLine(to: .init(x: 39, y: 91)); p.addLine(to: .init(x: 0, y: 91)); p.closeSubpath()
        }
    }

    private static var stems: Path {
        Path { p in
            p.move(to: .init(x: 117, y: 81)); p.addQuadCurve(to: .init(x: 117, y: 58), control: .init(x: 111, y: 69))
            p.move(to: .init(x: 115, y: 81)); p.addQuadCurve(to: .init(x: 83, y: 52), control: .init(x: 104, y: 58))
            p.move(to: .init(x: 122, y: 81)); p.addQuadCurve(to: .init(x: 153, y: 66), control: .init(x: 135, y: 66))
        }
    }

    private static var rightLeaf: Path {
        Path { p in
            p.move(to: .init(x: 116, y: 69))
            p.addQuadCurve(to: .init(x: 95, y: 48), control: .init(x: 96, y: 61))
            p.addLine(to: .init(x: 113, y: 52)); p.addLine(to: .init(x: 94, y: 41))
            p.addQuadCurve(to: .init(x: 103, y: 25), control: .init(x: 93, y: 31))
            p.addLine(to: .init(x: 115, y: 41)); p.addLine(to: .init(x: 108, y: 20))
            p.addQuadCurve(to: .init(x: 128, y: 16), control: .init(x: 118, y: 10))
            p.addLine(to: .init(x: 124, y: 34)); p.addLine(to: .init(x: 135, y: 16))
            p.addQuadCurve(to: .init(x: 151, y: 27), control: .init(x: 146, y: 16))
            p.addLine(to: .init(x: 136, y: 40)); p.addLine(to: .init(x: 156, y: 33))
            p.addQuadCurve(to: .init(x: 160, y: 48), control: .init(x: 162, y: 39))
            p.addLine(to: .init(x: 139, y: 49)); p.addLine(to: .init(x: 157, y: 55))
            p.addQuadCurve(to: .init(x: 142, y: 66), control: .init(x: 152, y: 64))
            p.addLine(to: .init(x: 131, y: 58)); p.addLine(to: .init(x: 136, y: 68))
            p.addQuadCurve(to: .init(x: 116, y: 69), control: .init(x: 125, y: 73)); p.closeSubpath()
            p.addEllipse(in: CGRect(x: 117, y: 42, width: 4, height: 9))
            p.addEllipse(in: CGRect(x: 128, y: 33, width: 3, height: 7))
        }
    }

    private static var rightLight: Path {
        Path { p in
            p.move(to: .init(x: 134, y: 20)); p.addQuadCurve(to: .init(x: 148, y: 27), control: .init(x: 143, y: 19))
            p.addLine(to: .init(x: 133, y: 42)); p.addLine(to: .init(x: 155, y: 36))
            p.addQuadCurve(to: .init(x: 157, y: 46), control: .init(x: 159, y: 43))
            p.addLine(to: .init(x: 136, y: 48)); p.addLine(to: .init(x: 153, y: 56))
            p.addLine(to: .init(x: 143, y: 63)); p.addLine(to: .init(x: 128, y: 54))
            p.addLine(to: .init(x: 120, y: 65)); p.addLine(to: .init(x: 124, y: 51))
            p.addLine(to: .init(x: 134, y: 20)); p.closeSubpath()
        }
    }

    private static var leftLeaf: Path {
        Path { p in
            p.move(to: .init(x: 99, y: 65))
            p.addQuadCurve(to: .init(x: 70, y: 69), control: .init(x: 83, y: 77))
            p.addLine(to: .init(x: 80, y: 60)); p.addLine(to: .init(x: 63, y: 64))
            p.addQuadCurve(to: .init(x: 56, y: 52), control: .init(x: 56, y: 60))
            p.addLine(to: .init(x: 77, y: 54)); p.addLine(to: .init(x: 57, y: 46))
            p.addQuadCurve(to: .init(x: 68, y: 35), control: .init(x: 59, y: 36))
            p.addLine(to: .init(x: 80, y: 47)); p.addLine(to: .init(x: 74, y: 32))
            p.addQuadCurve(to: .init(x: 93, y: 37), control: .init(x: 84, y: 29))
            p.addLine(to: .init(x: 91, y: 49)); p.addLine(to: .init(x: 98, y: 42))
            p.addQuadCurve(to: .init(x: 99, y: 65), control: .init(x: 106, y: 54)); p.closeSubpath()
            p.addEllipse(in: CGRect(x: 85, y: 55, width: 4, height: 6))
        }
    }

    private static var leftLight: Path {
        Path { p in
            p.move(to: .init(x: 60, y: 44)); p.addLine(to: .init(x: 68, y: 38))
            p.addLine(to: .init(x: 83, y: 51)); p.addLine(to: .init(x: 77, y: 35))
            p.addQuadCurve(to: .init(x: 90, y: 39), control: .init(x: 84, y: 34))
            p.addLine(to: .init(x: 90, y: 51)); p.addLine(to: .init(x: 98, y: 46))
            p.addQuadCurve(to: .init(x: 100, y: 62), control: .init(x: 102, y: 55))
            p.addLine(to: .init(x: 80, y: 51)); p.closeSubpath()
        }
    }

    private static var youngLeaf: Path {
        Path { p in
            p.move(to: .init(x: 142, y: 70))
            p.addCurve(to: .init(x: 174, y: 53), control1: .init(x: 139, y: 52), control2: .init(x: 162, y: 48))
            p.addCurve(to: .init(x: 142, y: 70), control1: .init(x: 167, y: 74), control2: .init(x: 153, y: 81)); p.closeSubpath()
        }
    }

    private static var youngShade: Path {
        Path { p in
            p.move(to: .init(x: 142, y: 70)); p.addLine(to: .init(x: 174, y: 53))
            p.addCurve(to: .init(x: 142, y: 70), control1: .init(x: 167, y: 74), control2: .init(x: 153, y: 81)); p.closeSubpath()
        }
    }

    private static var veins: Path {
        Path { p in
            p.move(to: .init(x: 117, y: 66)); p.addQuadCurve(to: .init(x: 133, y: 25), control: .init(x: 129, y: 41))
            p.move(to: .init(x: 98, y: 65)); p.addQuadCurve(to: .init(x: 66, y: 43), control: .init(x: 82, y: 47))
        }
    }

    private static var pot: Path {
        Path { p in
            p.move(to: .init(x: 99, y: 79)); p.addLine(to: .init(x: 136, y: 79))
            p.addLine(to: .init(x: 130, y: 94)); p.addQuadCurve(to: .init(x: 105, y: 94), control: .init(x: 118, y: 98))
            p.closeSubpath()
        }
    }

    private static var potLight: Path {
        Path { p in
            p.move(to: .init(x: 101, y: 82)); p.addLine(to: .init(x: 120, y: 82))
            p.addLine(to: .init(x: 117, y: 95)); p.addLine(to: .init(x: 106, y: 93)); p.closeSubpath()
        }
    }

    private static var rim: Path {
        Path { p in
            p.move(to: .init(x: 100, y: 80)); p.addQuadCurve(to: .init(x: 135, y: 80), control: .init(x: 117, y: 86))
        }
    }
}
