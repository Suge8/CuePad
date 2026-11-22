import SwiftUI

nonisolated enum Radius {
    static let chip: CGFloat = 6
    static let block: CGFloat = 12
    static let card: CGFloat = 16
    static let sheet: CGFloat = 22
    static let field: CGFloat = 28
    static let screen: CGFloat = 46
    #if os(iOS)
    static let row = block
    #else
    static let row: CGFloat = 8
    #endif

    static var nested: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: .fixed(block))) }
}
