#if os(iOS)
import SwiftUI

/// 贴在底部的纸里的把手报给纸那一层：拖了多远、松手时照去势会滑到哪。纸那一层只挪图层（`offset`），纸里不重排。
/// 按是哪一个气泡比（`Shown.identity`）：纸那一层每更新一次都新建这两个闭包，按闭包比的话把手次次重算；同一个气泡的拖法不变。
struct BubbleDrag: Equatable {
    /// 不可变、只拿来比：比较不在主线程上也读得了。
    nonisolated(unsafe) let bubble: AnyHashable
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ predicted: CGFloat) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.bubble == b.bubble }
}

extension EnvironmentValues {
    @Entry var bubbleDrag: BubbleDrag?
}
#endif
