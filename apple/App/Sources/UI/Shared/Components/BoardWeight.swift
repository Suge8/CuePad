import SwiftUI

/// 看板四列分轻重（Mac、iPad 的四列与手机的四行同一份）：推进中、等你是此刻要看的两列，重；待办、已完成是清单与回顾，轻。
/// 轻重只在这里定，各组件只问列要它那一样，不自己判断哪列轻：
/// - 卡的纸（`paper`）：每列一种同色系的淡调——推进中是纸本身（最亮的白），等你极淡的赭黄，待办中性淡灰，已完成淡石绿；
///   轻的两列比重的两列淡，一眼分得出列、不抢字（色值与对比度在 `Palette`）。
/// - 卡上的字（`titleInk`、`titleWeight`、`leadOpacity`）：轻的两列标题降一档墨（待办 ink2、已完成 ink3）、常规字重，开头的圈淡一档。
/// - 列头与行头的数（`BoardColumnHeader`、`BoardRowSpine`）：重的两列放大、着状态色（推进中靛青、等你赭黄），轻的两列与列名同字号、ink3。
/// - 宽（`share`，Mac 与 iPad 四列）：重的两列宽；轻的两列卡压成一行标题的矮卡，列宽仍放得下一行十来个字（`BoardColumns`）。
/// - 手机的行（`rowTiers`、`BoardRowLane`）：重的两行理想高各三排卡、行头随行高拉长；轻的两行只一排矮卡、行头紧凑。
/// 否决过：轻的两列去掉纸只留一层淡底（读成不可用的按钮）、推进中与等你身后垫一块托盘（页面多一块面）。
extension TaskBoard.Column {
    var light: Bool { self == .todo || self == .done }

    /// 卡的纸色：nil 是纸本身（`paper()`）。
    func paper(_ palette: Palette) -> Color? {
        switch self {
        case .todo: palette.todoPaper
        case .advancing: nil
        case .waiting: palette.waitingPaper
        case .done: palette.donePaper
        }
    }

    /// 卡标题的墨（推进中歇着的另淡一档，`BoardTaskCard`）。
    func titleInk(_ palette: Palette) -> Color {
        switch self {
        case .todo: palette.ink2
        case .done: palette.ink3
        case .advancing, .waiting: palette.ink
        }
    }

    /// 卡标题的字重：轻的两列常规，重的照卡的字（`TaskMetrics.lineFont`）。
    var titleWeight: Font.Weight? { light ? .regular : nil }

    /// 卡开头的圈：轻的两列淡一档。
    var leadOpacity: Double { light ? 0.72 : 1 }

    /// 列头、行头的数：重的两列着状态色，轻的 ink3。
    func countInk(_ palette: Palette) -> Color {
        switch self {
        case .advancing: palette.signature
        case .waiting: palette.waiting
        case .todo, .done: palette.ink3
        }
    }

    /// 四列并排时占几份宽（`BoardColumns`）。
    var share: CGFloat {
        switch self {
        case .todo: 0.95
        case .advancing: 1.25
        case .waiting: 1.05
        case .done: 0.9
        }
    }

    /// 手机竖版看板里这一行理想高叠几排卡（`BoardRowLane`；四行按理想高分屏高，`PhoneBoard`）。
    var rowTiers: Int { light ? 1 : 3 }
}
