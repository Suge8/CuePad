#if os(macOS)
import SwiftUI

/// 任务区各块的尺寸（手机按动态字体与 44pt 点按，Mac 用小字）。
enum TaskMetrics {
    static let font = Typography.body
    static let icon: CGFloat = 17
    static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipHeight: CGFloat = 24
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    static let title = Typography.heading
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let cardGap: CGFloat = 8
    // 任务行（`TaskLine`）：上级正文字号加一点字重、步骤小一档，圈也小一档
    static let lineFont = Typography.body.weight(.medium)
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 15
    static let stepRing: CGFloat = 13
    /// 圈那一列多宽（浮窗里的新建行按它缩进，字与任务标题对齐）、与标题隔多少；悬停的淡底是行的底（`RowStyle`），向两边让出去。
    static let ringColumn: CGFloat = 16
    static let columnGap: CGFloat = 10
}
#endif
