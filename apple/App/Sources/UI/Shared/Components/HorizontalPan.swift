#if os(iOS)
import SwiftUI
import UIKit

/// 只接横向的拖（行上的轻扫 `rowSwipes`、Cue 页等你卡换一件 `CueWaitDock`）：开始时横向速度明显大于纵向、不贴屏幕两边起手（贴边是返回与切页）、
/// 挂它的那一块要它（`allows`，按开始那一刻的横向速度）才开始，不抢列表滚动；页上的横拖（内容区右滑返回、根上切页）等它先判：它不要的才归它们。
struct HorizontalPan: UIGestureRecognizerRepresentable {
    let allows: (CGFloat) -> Bool
    let changed: (CGFloat) -> Void
    let ended: (_ commits: Bool, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) { context.coordinator.allows = allows }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: changed(pan.translation(in: pan.view).x)
        case .ended:
            // 松手那一下也可能带着一段位移（快滑时最后一次移动与松手同一帧）
            changed(pan.translation(in: pan.view).x)
            ended(true, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(false, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let edge: CGFloat = 28
        var allows: (CGFloat) -> Bool = { _ in true }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let x = pan.location(in: nil).x, width = pan.view?.window?.bounds.width ?? .infinity
            return abs(velocity.x) > abs(velocity.y) * 1.5 && x > Self.edge && x < width - Self.edge && allows(velocity.x)
        }

        /// 外层的横拖（导航栈的返回、根上切页）等这一行先判。
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other is UIPanGestureRecognizer, let view = recognizer.view, let outer = other.view, outer !== view, view.isDescendant(of: outer) else { return false }
            return (outer as? UIScrollView)?.panGestureRecognizer !== other
        }
    }
}
#endif
