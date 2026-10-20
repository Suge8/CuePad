import SwiftUI

/// 用量到了哪一档（上下文与订阅额度同一个口径，按已用的比例算）：七成起偏紧，九成起快满。
/// 铺色只在这里：余量足次要墨色，偏紧墨色，快满胭脂（不借赭黄、不用靛青）。App 的用量条、额度环与灵动岛上的额度同一份。
nonisolated enum UsageLevel: String, Codable, Sendable {
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
