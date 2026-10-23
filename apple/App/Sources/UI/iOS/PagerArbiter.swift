#if os(iOS)
import SwiftUI
import UIKit

/// 根上四页的横拖归谁（开始那一刻按状态给方向，同 Telegram 的文件夹切换）：
/// - 横向比纵向快才开始；手指下面横着能滚的内容（表格、附件条）还能往那边滚时让它先滚，滚到头再拖才翻页。
///   贴屏幕左右边（`edge` 以内）起手的不让：页里横滚的内容占满一屏（手机的任务看板）时，边缘是随时切页的那条路。
///   认领了横拖的滚动区（`claimsHorizontalDrags`，手机任务看板）里不贴边的横拖一律归它：滚到头也不翻页，只回弹。
///   那一侧没有页（最左的项目、没有可前进的 Cue）也接，只是越拖越沉（同系统滚动到头）：不接的话这一拖落到手指下面的行上，松手就点开了它。
/// - 页里的滚动等它先判（横着翻页时列表不跟着竖着滚）；行上的轻扫先判（`rowSwipes` 只认慢拖、那个方向有动作），行不要的才归它。
/// - 手指下面是正在输入的输入框时不开始。
final class PagerArbiter: NSObject, UIGestureRecognizerDelegate {
    enum Direction { case previous, next }

    /// 离屏幕左右边多近起手算"贴边"（同系统左缘返回的宽）。
    static let edge: CGFloat = 20

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        let motion = velocity == .zero ? pan.translation(in: view) : velocity
        guard abs(motion.x) > abs(motion.y) else { return false }
        let start = pan.location(in: view).x - pan.translation(in: view).x
        let edge = start < Self.edge || start > view.bounds.width - Self.edge
        return !Self.yields(toward: motion.x < 0 ? .next : .previous, at: pan.location(in: view), in: view, fromEdge: edge)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let view = recognizer.view, let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
        return scroll.isDescendant(of: view)
    }

    /// 手指下面有横着还能往这边滚的内容（贴边起手的不算），或正在输入的输入框：让给它。
    private static func yields(toward direction: Direction, at point: CGPoint, in root: UIView, fromEdge: Bool) -> Bool {
        var view = root.hitTest(point, with: nil)
        while let current = view, current !== root {
            if current.isFirstResponder, current is UITextInput { return true }
            if !fromEdge, let scroll = current as? UIScrollView, DragClaim.claimed.contains(scroll) { return true }
            if !fromEdge, let scroll = current as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 {
                let inset = scroll.adjustedContentInset, x = scroll.contentOffset.x
                let room = direction == .previous ? x > -inset.left + 1 : x < scroll.contentSize.width - scroll.bounds.width + inset.right - 1
                if room { return true }
            }
            view = current.superview
        }
        return false
    }
}
extension View {
    /// 挂在一个滚动区的内容里：这块滚动区里不贴边起手的横拖都归页里（行自己横滑、滚到头回弹），不翻页（`PagerArbiter`）。
    func claimsHorizontalDrags() -> some View { background { DragClaim() } }
}

/// 认领横拖的记号：挂上窗口时把外面最近的那个滚动区记下来。
private struct DragClaim: UIViewRepresentable {
    @MainActor static let claimed = NSHashTable<UIScrollView>.weakObjects()

    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ marker: Marker, context: Context) {}

    final class Marker: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            guard window != nil, let scroll = sequence(first: self as UIView, next: { $0.superview }).lazy.compactMap({ $0 as? UIScrollView }).first else { return }
            DragClaim.claimed.add(scroll)
        }
    }
}
#endif
