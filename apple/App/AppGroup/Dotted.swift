import SwiftUI

nonisolated struct Dotted: Hashable, Sendable {
    static let separator = " · "

    let parts: [String]

    init(_ parts: [String?]) { self.parts = parts.compactMap { $0 }.filter { !$0.isEmpty } }
    init(_ parts: String?...) { self.init(parts) }

    var isEmpty: Bool { parts.isEmpty }
    var visible: String { parts.joined(separator: Self.separator) }
    var spoken: String { parts.joined(separator: String(localized: "，", comment: "读屏在分段处停顿的标点")) }

    var nonEmpty: Dotted? { isEmpty ? nil : self }

    static func + (lhs: Dotted, rhs: Dotted) -> Dotted { Dotted(lhs.parts + rhs.parts) }
}

extension Text {
    init(_ dotted: Dotted) { self = Text(verbatim: dotted.visible).accessibilityLabel(dotted.spoken) }
}

extension Dotted {
    static var inline: Text { Text(separator) }
}
