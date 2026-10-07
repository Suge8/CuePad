#if os(iOS)
import SwiftUI
import UIKit

/// 轻扫一行（或一张卡）做的事：露出的图标与松手后的动作。
struct SwipeAction {
    let symbol: String
    let run: () -> Void
}

extension View {
    /// 向右、向左轻扫：跟着手指走，露出那一边的图标，过阈值有触感、图标变实，松手生效后回位。
    /// 任务大纲里是缩进与反缩进，灵感卡上向右是"要做"。没有动作的方向只给一点阻力、不露图标。
    func rowSwipe(right: SwipeAction?, left: SwipeAction? = nil) -> some View {
        modifier(RowSwipe(right: right, left: left))
    }
}

/// 只在横向明显快于纵向时接手，不抢列表滚动与屏幕边缘的返回手势。
private struct RowSwipe: ViewModifier {
    let right: SwipeAction?
    let left: SwipeAction?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var translation: CGFloat = 0

    private static let threshold: CGFloat = 56
    private static let reach: CGFloat = 88

    private var action: SwipeAction? { translation > 0 ? right : translation < 0 ? left : nil }
    private var armed: Bool { action != nil && abs(translation) >= Self.threshold }

    /// 能做的方向跟手（过阈值后放慢），做不了的方向只挪一点。
    private var offset: CGFloat {
        let distance = abs(translation)
        let shown = action == nil ? min(distance * 0.15, 12)
            : min(distance, Self.threshold) + max(distance - Self.threshold, 0) * 0.3
        return min(shown, Self.reach) * (translation < 0 ? -1 : 1)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: translation > 0 ? .leading : .trailing) {
                if let action, translation != 0 {
                    Image(systemName: action.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(armed ? palette.ink : palette.ink3)
                        .scaleEffect(armed ? 1 : 0.85)
                        .frame(width: abs(offset), alignment: .center)
                        .opacity(min(abs(offset) / Self.threshold, 1))
                        .accessibilityHidden(true)
                }
            }
            .gesture(HorizontalPan(changed: { translation = $0 }, ended: end))
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { !$0 && $1 }
            .animation(Motion.quick, value: armed)
    }

    /// `commits`：手指正常松开才生效；系统取消手势（来电、被别的手势接走）只回位。
    private func end(commits: Bool) {
        if commits, armed { action?.run() }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { translation = 0 }
    }
}

/// 只接横向的拖：开始时横向速度明显大于纵向、且不在屏幕左缘（那里是返回手势）才开始。
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ commits: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: changed(pan.translation(in: pan.view).x)
        case .ended: ended(true)
        case .cancelled, .failed: ended(false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let edge: CGFloat = 28

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5 && pan.location(in: nil).x > Self.edge
        }
    }
}
#endif
