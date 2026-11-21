import SwiftUI

nonisolated enum UsageLevel: Sendable {
    case roomy, tight, critical

    static let tightFraction = 0.7
    static let criticalFraction = 0.9

    init(used fraction: Double) {
        self = fraction >= Self.criticalFraction ? .critical : fraction >= Self.tightFraction ? .tight : .roomy
    }
}

extension UsageLevel {
    func ink(_ palette: Palette) -> Color {
        switch self {
        case .roomy: palette.ink2
        case .tight: palette.ink
        case .critical: palette.failure
        }
    }
}
