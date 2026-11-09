import SwiftUI

/// 轻重只在这里定，各组件只问列要它那一样，不自己判断哪列轻：
/// 否决过：轻的两列去掉纸只留一层淡底（读成不可用的按钮）、推进中与等你身后垫一块托盘（页面多一块面）。
extension TaskBoard.Column {
    var light: Bool { self == .todo || self == .done }

    func paper(_ palette: Palette) -> Color? {
        switch self {
        case .todo: palette.todoPaper
        case .advancing: nil
        case .waiting: palette.waitingPaper
        case .done: palette.donePaper
        }
    }

    func titleInk(_ palette: Palette) -> Color {
        switch self {
        case .todo: palette.ink2
        case .done: palette.ink3
        case .advancing, .waiting: palette.ink
        }
    }

    var titleWeight: Font.Weight? { light ? .regular : nil }

    var leadOpacity: Double { light ? 0.72 : 1 }

    func countInk(_ palette: Palette) -> Color {
        switch self {
        case .advancing: palette.signature
        case .waiting: palette.waiting
        case .todo, .done: palette.ink3
        }
    }

    var rowTiers: Int { light ? 1 : 3 }
}
