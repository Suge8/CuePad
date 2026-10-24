#if os(iOS)
import UIKit

/// 根上三页的横拖归谁（开始那一刻按状态给方向，同 Telegram 的文件夹切换）：
/// - 横向比纵向快才开始；手指下面横着能滚的内容（表格、附件条、进展页看板的行）还能往那边滚时让它先滚，滚到头再拖才翻页。
///   手指下面横着滚不动的（行与行之间、空行、行尾的空、行头）都是翻页。
///   那一侧没有页（最左的项目、没有可前进的 Cue）也接，只是越拖越沉（同系统滚动到头）：不接的话这一拖落到手指下面的行上，松手就点开了它。
/// - 页里的滚动等它先判（横着翻页时列表不跟着竖着滚）；行上的轻扫先判（`rowSwipes` 只认慢拖、那个方向有动作），行不要的才归它。
/// - 手指下面是正在输入的输入框时不开始。
final class PagerArbiter: NSObject, UIGestureRecognizerDelegate {
    enum Direction { case previous, next }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        let motion = velocity == .zero ? pan.translation(in: view) : velocity
        guard abs(motion.x) > abs(motion.y) else { return false }
        return !Self.yields(toward: motion.x < 0 ? .next : .previous, at: pan.location(in: view), in: view)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let view = recognizer.view, let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
        return scroll.isDescendant(of: view)
    }

    /// 手指下面有横着还能往这边滚的内容，或正在输入的输入框：让给它。
    private static func yields(toward direction: Direction, at point: CGPoint, in root: UIView) -> Bool {
        var view = root.hitTest(point, with: nil)
        while let current = view, current !== root {
            if current.isFirstResponder, current is UITextInput { return true }
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 {
                let inset = scroll.adjustedContentInset, x = scroll.contentOffset.x
                let room = direction == .previous ? x > -inset.left + 1 : x < scroll.contentSize.width - scroll.bounds.width + inset.right - 1
                if room { return true }
            }
            view = current.superview
        }
        return false
    }
}
#endif
