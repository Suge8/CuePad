#if os(iOS)
import SwiftUI
import UIKit

/// 手指下的滚动区还能往那个方向走时先走它——放大着的图与 PDF 拖动是看图、捏合是缩小，往下翻过的长文往下拉是往回翻，
/// 左边还有一份时左缘右滑是翻回上一份。"放大着没有""翻过没有"都直接看手指下的滚动区，不另存状态。
/// 做法：给系统的每个关闭手势配一个只看不拦的守门手势，系统的要等它失败才能开始；守门的在手指落下那一刻就定（让给页里就认下，否则失败）。
/// SwiftUI 的 zoom 转场没有"可不可以开始收起"的接口（UIKit 的 `interactiveDismissShouldBegin`），系统手势按它们公开的 `name` 认。
/// 顺带关掉分页滚动区的滚动边缘效果：系统在栏后面按它垫一层雾（docs/layout.md「沉浸式的栏」不垫），`scrollEdgeEffectHidden` 管不到 `TabView` 的分页。
struct PreviewDismissGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {}

    final class Anchor: UIView {
        private var gated = 0
        private var pagerFound = false

        override func layoutSubviews() {
            super.layoutSubviews()
            guard gated < 3 || !pagerFound, window != nil else { return }
            for view in sequence(first: self as UIView, next: \.superview) {
                let recognizers = view.gestureRecognizers ?? []
                let systems = recognizers.compactMap { system in Rule(system.name).map { (system, $0) } }
                guard !systems.isEmpty else { continue }
                pagerFound = pagerFound || PreviewDismissGuard.hidePagerEdges(in: view)
                for (system, rule) in systems where !recognizers.contains(where: { ($0 as? Gate)?.rule == rule }) {
                    let gate = Gate(rule)
                    view.addGestureRecognizer(gate)
                    system.require(toFail: gate)
                    gated += 1
                }
            }
        }
    }

    private static func hidePagerEdges(in container: UIView) -> Bool {
        if let pager = container as? UIScrollView, pager.isPagingEnabled {
            pager.topEdgeEffect.isHidden = true
            pager.bottomEdgeEffect.isHidden = true
            return true
        }
        return container.subviews.contains { hidePagerEdges(in: $0) }
    }

    enum Rule {
        case swipeDown, leadingEdge, pinch

        init?(_ name: String?) {
            switch name {
            case "com.apple.UIKit.ZoomInteractiveDismissSwipeDown": self = .swipeDown
            case "com.apple.UIKit.ZoomInteractiveDismissLeadingEdgePan": self = .leadingEdge
            case "com.apple.UIKit.ZoomInteractiveDismissPinch": self = .pinch
            default: return nil
            }
        }

        func yields(to scroll: UIScrollView) -> Bool {
            let zoomed = scroll.zoomScale > scroll.minimumZoomScale + 0.01
            let inset = scroll.adjustedContentInset
            return switch self {
            case .swipeDown: zoomed || scroll.contentOffset.y > -inset.top + 1
            case .leadingEdge: scroll.contentOffset.x > -inset.left + 1
            case .pinch: zoomed
            }
        }
    }

    final class Gate: UIGestureRecognizer, UIGestureRecognizerDelegate {
        let rule: Rule

        init(_ rule: Rule) {
            self.rule = rule
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible else { return }
            let yields = touches.contains { touch in
                touch.view.map { sequence(first: $0, next: \.superview).contains { ($0 as? UIScrollView).map(rule.yields) ?? false } } ?? false
            }
            state = yields ? .recognized : .failed
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
