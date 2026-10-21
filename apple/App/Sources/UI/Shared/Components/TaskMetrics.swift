import SwiftUI

/// 任务区各块的尺寸：手机按动态字体与 44pt 点按，Mac 用小字。
enum TaskMetrics {
    #if os(iOS)
    nonisolated static let rowHeight: CGFloat = 44
    static let caption = Font.footnote
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    // 任务行（`TaskLine`）：上级正文字号、步骤小一档，圈也小一档
    static let lineFont = Font.body
    static let stepFont = Font.subheadline
    static let ring: CGFloat = 24
    static let stepRing: CGFloat = 16
    /// 圈那一列（也是它的点按区）多宽、与标题隔多少；行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let cardHeight: CGFloat = 60
    static let cardLead: CGFloat = 24
    static let cardGlyph: CGFloat = 13
    #else
    nonisolated static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    // 任务行（`TaskLine`）：上级正文字号加一点字重、步骤小一档，圈也小一档
    static let lineFont = Typography.body.weight(.medium)
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 17
    static let stepRing: CGFloat = 13
    /// 圈那一列多宽（新建行按它缩进，字与任务标题对齐）、与标题隔多少；悬停的淡底是行的底（`RowStyle`），向两边让出去。
    static let ringColumn: CGFloat = 18
    static let columnGap: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let cardHeight: CGFloat = 48
    static let cardLead: CGFloat = 16
    static let cardGlyph: CGFloat = 12
    #endif
}

/// 任务看板的卡（`BoardCard`）：同一种卡一样高（`cardHeight`），左右内边距 `cardPadding`、圆角 `cardRadius`；开头的记号占 `cardLead` 见方，
/// 看全部项目时标题前一个 `cardGlyph` 的项目小图形；卡离泳道边与卡与卡之间都是 `BoardCardMetrics.inset`（泳道圆角 = 卡圆角 + 它，同心）。
enum BoardCardMetrics {
    static let inset: CGFloat = 8
    static let gap: CGFloat = 8
    static var radius: CGFloat { TaskMetrics.cardRadius }
}
