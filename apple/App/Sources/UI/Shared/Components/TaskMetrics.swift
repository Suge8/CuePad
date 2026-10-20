import SwiftUI

/// 任务区各块的尺寸：手机按动态字体与 44pt 点按，Mac 用小字。
enum TaskMetrics {
    #if os(iOS)
    static let rowHeight: CGFloat = 44
    static let caption = Font.footnote
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    // 任务行（`TaskLine`）：上级正文字号、步骤小一档，圈也小一档
    static let lineFont = Font.body
    static let stepFont = Font.subheadline
    static let ring: CGFloat = 20
    static let stepRing: CGFloat = 16
    /// 圈那一列（也是它的点按区）多宽、与标题隔多少；行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
    #else
    static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    // 任务行（`TaskLine`）：上级正文字号加一点字重、步骤小一档，圈也小一档
    static let lineFont = Typography.body.weight(.medium)
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 15
    static let stepRing: CGFloat = 13
    /// 圈那一列多宽（新建行按它缩进，字与任务标题对齐）、与标题隔多少；悬停的淡底是行的底（`RowStyle`），向两边让出去。
    static let ringColumn: CGFloat = 16
    static let columnGap: CGFloat = 10
    #endif
}
