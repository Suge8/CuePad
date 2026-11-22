import SwiftUI

nonisolated enum Glyph {
    static let mark = Font.system(size: 9, weight: .bold)
    static let chevronSize: CGFloat = 11
    static func chevron(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static let small = Font.system(size: 12, weight: .semibold)
    static let rowSize: CGFloat = 13
    static let row = Font.system(size: rowSize, weight: .medium)
    static let control = Font.system(size: 15)
    static let largeSize: CGFloat = 20
    static let large = Font.system(size: largeSize)
    static let projectIdentity: CGFloat = 24
    static let hero = Font.system(size: 56)
}
