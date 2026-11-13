import SwiftUI

/// 轻重只在这里定，各组件只问列要它那一样，不自己判断哪列轻：
/// 否决过：轻的两列去掉纸只留一层淡底（读成不可用的按钮）、轻的两列各带一档淡灰淡绿的纸（和桌面太近，读成一排空心框）、
/// 列身后垫托盘（只垫两列、四列都垫都试过，`BoardLane`）。
extension TaskBoard.Column {
    var light: Bool { self == .todo || self == .done }

    func paper(_ palette: Palette) -> Color? {
        switch self {
        case .waiting: palette.waitingPaper
        case .todo, .advancing, .done: nil
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

    /// 列宽的份数：待办与已完成是清单，地方让给正在发生的两列。固定的比例，不随列里有几张卡变（按内容分宽否决过，见 `BoardWidths`）。
    var share: CGFloat { light ? 0.85 : 1.15 }
}
