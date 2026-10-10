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
}
#endif
