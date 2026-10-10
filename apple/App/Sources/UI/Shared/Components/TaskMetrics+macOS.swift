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
}
#endif
