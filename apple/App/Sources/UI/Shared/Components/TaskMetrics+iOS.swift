#if os(iOS)
import SwiftUI

/// 任务区各块的尺寸（手机按动态字体与 44pt 点按，Mac 用小字）。
enum TaskMetrics {
    static let font = Font.subheadline
    static let icon: CGFloat = 28
    static let rowHeight: CGFloat = 44
    static let caption = Font.footnote
    static let chipHeight: CGFloat = 30
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    static let title = Typography.heading
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let cardGap: CGFloat = 10
    // 任务行（`TaskLine`）：上级正文字号、步骤小一档，圈也小一档
    static let lineFont = Font.body
    static let stepFont = Font.subheadline
    static let ring: CGFloat = 20
    static let stepRing: CGFloat = 16
    /// 圈那一列（也是它的点按区）多宽、与标题隔多少；行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
}
#endif
