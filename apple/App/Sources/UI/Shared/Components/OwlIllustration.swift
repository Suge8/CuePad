import SwiftUI

/// 暮色斜枝上的猫头鹰：不对称心形面盘朝右，胸前纵纹与折叠覆羽沿身体向下收拢。
nonisolated enum OwlIllustration {
    static func artwork() -> ProjectIllustration {
        ProjectIllustration(pigments: [0x39354F, 0x62536F, 0x241F34, 0xA99B96, 0xD6A15A, 0xE4D8BE], layers: [
            .init(path: distantLeaves, ink: 1, coverage: 0.52),
            .init(path: branch, ink: 2),
            .init(path: bark.strokedPath(StrokeStyle(lineWidth: 1.4)), ink: 3, coverage: 0.6),
            .init(path: tail, ink: 2),
            .init(path: tailBars.strokedPath(StrokeStyle(lineWidth: 1.5)), ink: 3, coverage: 0.7),
            .init(path: body, ink: 3),
            .init(path: breast, ink: 5),
            .init(path: breastShade, ink: 4, coverage: 0.48),
            .init(path: wing, ink: 1),
            .init(path: wingLight, ink: 4, coverage: 0.7),
            .init(path: flightFeathers.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round)), ink: 2),
            .init(path: coverts, ink: 3),
            .init(path: chestMarks, ink: 1),
            .init(path: head, ink: 4),
            .init(path: crown, ink: 1, coverage: 0.65),
            .init(path: faceRim, ink: 2),
            .init(path: face, ink: 5),
            .init(path: faceShade, ink: 3, coverage: 0.58),
            .init(path: brows.strokedPath(StrokeStyle(lineWidth: 1.2)), ink: 3),
            .init(path: sockets, ink: 2),
            .init(path: irises, ink: 4),
            .init(path: pupils, ink: 2),
            .init(path: glints, ink: 5),
            .init(path: beak, ink: 4),
            .init(path: talons.strokedPath(StrokeStyle(lineWidth: 1.8, lineCap: .round)), ink: 4)
        ])
    }

    private static var branch: Path {
        Path { p in
            p.move(to: .init(x: 16, y: 93)); p.addQuadCurve(to: .init(x: 123, y: 73), control: .init(x: 76, y: 78))
            p.addLine(to: .init(x: 174, y: 66)); p.addLine(to: .init(x: 196, y: 55))
            p.addLine(to: .init(x: 181, y: 67)); p.addLine(to: .init(x: 204, y: 65))
            p.addLine(to: .init(x: 204, y: 68)); p.addLine(to: .init(x: 124, y: 79))
            p.addQuadCurve(to: .init(x: 16, y: 99), control: .init(x: 62, y: 88)); p.closeSubpath()
            p.move(to: .init(x: 144, y: 72)); p.addLine(to: .init(x: 153, y: 84))
            p.addLine(to: .init(x: 169, y: 88)); p.addLine(to: .init(x: 154, y: 87))
            p.addLine(to: .init(x: 138, y: 74)); p.closeSubpath()
        }
    }

    private static var bark: Path {
        Path { p in
            p.move(to: .init(x: 28, y: 92)); p.addQuadCurve(to: .init(x: 72, y: 83), control: .init(x: 48, y: 86))
            p.move(to: .init(x: 115, y: 76)); p.addQuadCurve(to: .init(x: 177, y: 69), control: .init(x: 143, y: 71))
        }
    }

    private static var tail: Path {
        Path { p in
            p.move(to: .init(x: 74, y: 67)); p.addLine(to: .init(x: 97, y: 68))
            p.addLine(to: .init(x: 96, y: 88)); p.addLine(to: .init(x: 88, y: 86))
            p.addLine(to: .init(x: 82, y: 89)); p.closeSubpath()
        }
    }

    private static var tailBars: Path {
        Path { p in
            p.move(to: .init(x: 79, y: 77)); p.addLine(to: .init(x: 96, y: 77))
            p.move(to: .init(x: 82, y: 83)); p.addLine(to: .init(x: 95, y: 83))
        }
    }

    private static var body: Path {
        Path { p in
            p.move(to: .init(x: 65, y: 33))
            p.addCurve(to: .init(x: 106, y: 42), control1: .init(x: 81, y: 27), control2: .init(x: 104, y: 27))
            p.addCurve(to: .init(x: 105, y: 67), control1: .init(x: 113, y: 50), control2: .init(x: 111, y: 61))
            p.addQuadCurve(to: .init(x: 91, y: 78), control: .init(x: 104, y: 77))
            p.addLine(to: .init(x: 77, y: 77)); p.addQuadCurve(to: .init(x: 61, y: 58), control: .init(x: 61, y: 73))
            p.addQuadCurve(to: .init(x: 65, y: 33), control: .init(x: 57, y: 42)); p.closeSubpath()
        }
    }

    private static var breast: Path {
        Path { p in
            p.move(to: .init(x: 83, y: 40)); p.addLine(to: .init(x: 101, y: 38))
            p.addQuadCurve(to: .init(x: 105, y: 67), control: .init(x: 115, y: 55))
            p.addQuadCurve(to: .init(x: 91, y: 76), control: .init(x: 102, y: 76))
            p.addLine(to: .init(x: 80, y: 73)); p.addQuadCurve(to: .init(x: 83, y: 40), control: .init(x: 86, y: 60))
            p.closeSubpath()
        }
    }

    private static var breastShade: Path {
        Path { p in
            p.move(to: .init(x: 100, y: 43)); p.addQuadCurve(to: .init(x: 105, y: 67), control: .init(x: 112, y: 54))
            p.addQuadCurve(to: .init(x: 91, y: 76), control: .init(x: 102, y: 76))
            p.addLine(to: .init(x: 81, y: 73)); p.addQuadCurve(to: .init(x: 100, y: 43), control: .init(x: 105, y: 65))
            p.closeSubpath()
        }
    }

    private static var wing: Path {
        Path { p in
            p.move(to: .init(x: 67, y: 37))
            p.addQuadCurve(to: .init(x: 86, y: 41), control: .init(x: 78, y: 29))
            p.addCurve(to: .init(x: 78, y: 77), control1: .init(x: 94, y: 55), control2: .init(x: 87, y: 70))
            p.addQuadCurve(to: .init(x: 61, y: 62), control: .init(x: 65, y: 72))
            p.addQuadCurve(to: .init(x: 67, y: 37), control: .init(x: 55, y: 48)); p.closeSubpath()
        }
    }

    private static var wingLight: Path {
        Path { p in
            p.move(to: .init(x: 65, y: 42)); p.addQuadCurve(to: .init(x: 83, y: 42), control: .init(x: 73, y: 34))
            p.addQuadCurve(to: .init(x: 84, y: 61), control: .init(x: 90, y: 52))
            p.addLine(to: .init(x: 76, y: 69)); p.addQuadCurve(to: .init(x: 65, y: 42), control: .init(x: 61, y: 58))
            p.closeSubpath()
        }
    }

    private static var flightFeathers: Path {
        Path { p in
            p.move(to: .init(x: 65, y: 52)); p.addQuadCurve(to: .init(x: 75, y: 72), control: .init(x: 65, y: 66))
            p.move(to: .init(x: 72, y: 53)); p.addQuadCurve(to: .init(x: 78, y: 70), control: .init(x: 72, y: 65))
            p.move(to: .init(x: 80, y: 53)); p.addQuadCurve(to: .init(x: 81, y: 66), control: .init(x: 82, y: 59))
        }
    }

    private static var coverts: Path {
        Path { p in
            for point in [CGPoint(x: 65, y: 43), .init(x: 74, y: 40), .init(x: 81, y: 45), .init(x: 69, y: 49), .init(x: 77, y: 50)] {
                p.move(to: point)
                p.addQuadCurve(to: .init(x: point.x + 3, y: point.y + 5), control: .init(x: point.x - 1, y: point.y + 3))
                p.addLine(to: .init(x: point.x + 5, y: point.y + 1)); p.closeSubpath()
            }
        }
    }

    private static var chestMarks: Path {
        Path { p in
            for point in [CGPoint(x: 91, y: 48), .init(x: 99, y: 50), .init(x: 88, y: 57), .init(x: 96, y: 59), .init(x: 103, y: 60), .init(x: 90, y: 67)] {
                p.move(to: point); p.addLine(to: .init(x: point.x + 2, y: point.y + 1))
                p.addLine(to: .init(x: point.x + 1, y: point.y + 5)); p.closeSubpath()
            }
        }
    }

    private static var head: Path {
        Path { p in
            p.move(to: .init(x: 59, y: 25))
            p.addCurve(to: .init(x: 83, y: 9), control1: .init(x: 59, y: 12), control2: .init(x: 71, y: 8))
            p.addCurve(to: .init(x: 109, y: 24), control1: .init(x: 100, y: 7), control2: .init(x: 110, y: 14))
            p.addQuadCurve(to: .init(x: 103, y: 41), control: .init(x: 113, y: 33))
            p.addLine(to: .init(x: 92, y: 48)); p.addLine(to: .init(x: 76, y: 45))
            p.addQuadCurve(to: .init(x: 59, y: 25), control: .init(x: 58, y: 42)); p.closeSubpath()
        }
    }

    private static var crown: Path {
        Path { p in
            p.move(to: .init(x: 60, y: 24)); p.addQuadCurve(to: .init(x: 83, y: 9), control: .init(x: 60, y: 8))
            p.addQuadCurve(to: .init(x: 109, y: 24), control: .init(x: 110, y: 6))
            p.addLine(to: .init(x: 100, y: 19)); p.addLine(to: .init(x: 90, y: 23))
            p.addQuadCurve(to: .init(x: 60, y: 24), control: .init(x: 75, y: 14)); p.closeSubpath()
        }
    }

    private static var faceRim: Path {
        Path { p in
            p.move(to: .init(x: 65, y: 24)); p.addQuadCurve(to: .init(x: 88, y: 21), control: .init(x: 74, y: 12))
            p.addQuadCurve(to: .init(x: 105, y: 20), control: .init(x: 101, y: 12))
            p.addCurve(to: .init(x: 92, y: 46), control1: .init(x: 115, y: 29), control2: .init(x: 103, y: 41))
            p.addCurve(to: .init(x: 65, y: 24), control1: .init(x: 73, y: 47), control2: .init(x: 60, y: 35))
            p.closeSubpath()
        }
    }

    private static var face: Path {
        Path { p in
            p.move(to: .init(x: 68, y: 25)); p.addQuadCurve(to: .init(x: 88, y: 25), control: .init(x: 76, y: 15))
            p.addQuadCurve(to: .init(x: 103, y: 21), control: .init(x: 101, y: 16))
            p.addCurve(to: .init(x: 92, y: 43), control1: .init(x: 111, y: 30), control2: .init(x: 102, y: 39))
            p.addCurve(to: .init(x: 68, y: 25), control1: .init(x: 76, y: 43), control2: .init(x: 63, y: 34))
            p.closeSubpath()
        }
    }

    private static var faceShade: Path {
        Path { p in
            p.move(to: .init(x: 69, y: 25)); p.addQuadCurve(to: .init(x: 81, y: 20), control: .init(x: 74, y: 18))
            p.addQuadCurve(to: .init(x: 76, y: 34), control: .init(x: 69, y: 26))
            p.addLine(to: .init(x: 91, y: 42)); p.addQuadCurve(to: .init(x: 69, y: 25), control: .init(x: 64, y: 39))
            p.closeSubpath()
        }
    }

    private static var brows: Path {
        Path { p in
            p.move(to: .init(x: 71, y: 25)); p.addQuadCurve(to: .init(x: 86, y: 28), control: .init(x: 80, y: 21))
            p.move(to: .init(x: 91, y: 27)); p.addQuadCurve(to: .init(x: 103, y: 24), control: .init(x: 97, y: 20))
        }
    }

    private static var sockets: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 73, y: 25, width: 11, height: 11))
            p.addEllipse(in: CGRect(x: 92, y: 24, width: 10, height: 11))
        }
    }

    private static var irises: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 75, y: 27, width: 7, height: 7))
            p.addEllipse(in: CGRect(x: 94, y: 26, width: 6, height: 7))
        }
    }

    private static var pupils: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 78, y: 27, width: 3.5, height: 6))
            p.addEllipse(in: CGRect(x: 96, y: 26, width: 3.5, height: 6))
        }
    }

    private static var glints: Path {
        Path { p in
            p.addRect(CGRect(x: 78, y: 27, width: 1.2, height: 1.2))
            p.addRect(CGRect(x: 96, y: 26, width: 1.2, height: 1.2))
        }
    }

    private static var beak: Path {
        Path { p in
            p.move(to: .init(x: 86, y: 32)); p.addLine(to: .init(x: 91, y: 31))
            p.addLine(to: .init(x: 93, y: 35)); p.addLine(to: .init(x: 90, y: 41))
            p.addLine(to: .init(x: 87, y: 37)); p.closeSubpath()
        }
    }

    private static var talons: Path {
        Path { p in
            p.move(to: .init(x: 81, y: 75)); p.addLine(to: .init(x: 80, y: 80)); p.addLine(to: .init(x: 82, y: 83))
            p.move(to: .init(x: 85, y: 76)); p.addLine(to: .init(x: 84, y: 80)); p.addLine(to: .init(x: 86, y: 82))
            p.move(to: .init(x: 97, y: 74)); p.addLine(to: .init(x: 96, y: 78)); p.addLine(to: .init(x: 98, y: 81))
            p.move(to: .init(x: 101, y: 73)); p.addLine(to: .init(x: 100, y: 78)); p.addLine(to: .init(x: 102, y: 80))
        }
    }

    private static var distantLeaves: Path {
        Path { p in
            p.move(to: .init(x: 177, y: 63)); p.addQuadCurve(to: .init(x: 174, y: 43), control: .init(x: 165, y: 50))
            p.addQuadCurve(to: .init(x: 177, y: 63), control: .init(x: 184, y: 49)); p.closeSubpath()
            p.move(to: .init(x: 187, y: 59)); p.addQuadCurve(to: .init(x: 207, y: 44), control: .init(x: 188, y: 45))
            p.addQuadCurve(to: .init(x: 187, y: 59), control: .init(x: 205, y: 58)); p.closeSubpath()
        }
    }
}
