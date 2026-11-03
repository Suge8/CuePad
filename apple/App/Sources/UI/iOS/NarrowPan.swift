#if os(iOS)
import SwiftUI
import UIKit

/// 只存手势的呈现进度；侧栏开合的权威值仍是 Workspace.navigation。
@Observable
final class NarrowSlide {
    var progress: CGFloat = 0

    func set(open: Bool, velocity: CGFloat = 0, reduceMotion: Bool) {
        let target: CGFloat = open ? 1 : 0
        let distance = target - progress
        guard distance != 0 else { return }
        let speed = velocity / distance
        withAnimation(Motion.spatial(Motion.nudge(velocity: speed), reduceMotion: reduceMotion)) { progress = target }
    }
}

/// 只在根上横拖；推入页把返回完全交给系统。横向内容还可滚时先让它滚，屏边起手仍可收开侧栏。
/// 输入框内部保留选字，其他位置允许收键盘再导航；竖滚与会话条的点按不抢。
struct NarrowPan: UIGestureRecognizerRepresentable {
    let slide: NarrowSlide
    let workspace: Workspace
    let reduceMotion: Bool

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Arbiter { Arbiter() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.open = workspace.sidebarOpen
        pan.isEnabled = workspace.layout == .narrow && workspace.path.isEmpty
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        guard workspace.layout == .narrow, let view = pan.view else { return }
        let width = max(view.bounds.width, 1)
        switch pan.state {
        case .began:
            context.coordinator.start = slide.progress
            view.window?.endEditing(true)
        case .changed:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                slide.progress = min(max(context.coordinator.start + pan.translation(in: view).x / width, 0), 1)
            }
        case .ended, .cancelled:
            let speed = pan.velocity(in: view).x / width
            let open = pan.state == .cancelled ? workspace.sidebarOpen : slide.progress + speed * Self.projection > 0.5
            workspace.sidebarOpen = open
            slide.set(open: open, velocity: speed, reduceMotion: reduceMotion)
        default: break
        }
    }

    private static let projection: CGFloat = 0.2

    final class Arbiter: NSObject, UIGestureRecognizerDelegate {
        var open = false
        var start: CGFloat = 0
        private static let edge: CGFloat = 20

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let root = pan.view else { return false }
            let velocity = pan.velocity(in: root)
            guard abs(velocity.x) > abs(velocity.y), open ? velocity.x < 0 : velocity.x > 0 else { return false }
            let point = pan.location(in: root)
            let start = point.x - pan.translation(in: root).x
            let edge = start < Self.edge || start > root.bounds.width - Self.edge
            var hit = root.hitTest(point, with: nil)
            while let view = hit, view !== root {
                if view.isFirstResponder, view is UITextInput { return false }
                if !edge, let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.contentSize.width > scroll.bounds.width + 1 {
                    let inset = scroll.adjustedContentInset
                    let room = velocity.x > 0
                        ? scroll.contentOffset.x > -inset.left + 1
                        : scroll.contentOffset.x < scroll.contentSize.width - scroll.bounds.width + inset.right - 1
                    if room { return false }
                }
                hit = view.superview
            }
            return true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let root = recognizer.view, let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
            return scroll.isDescendant(of: root)
        }
    }
}

/// 只向本窗口交还键盘；按钮、深链与手势打开侧栏走同一个变化，不影响其他场景的输入焦点。
struct NarrowKeyboard: UIViewRepresentable {
    let sidebarOpen: Bool

    func makeUIView(context: Context) -> UIView { UIView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: UIView, context: Context) {
        if sidebarOpen, !context.coordinator.wasOpen { view.window?.endEditing(true) }
        context.coordinator.wasOpen = sidebarOpen
    }

    final class Coordinator { var wasOpen = false }
}
#endif
