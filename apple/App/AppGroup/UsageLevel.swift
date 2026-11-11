import SwiftUI

/// 上下文与订阅额度同一个口径，按已用的比例算。铺色只在这里：余量足次要墨色，偏紧墨色，快满胭脂（不借赭黄、不用靛青）。App 的用量条与额度环共用。
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
