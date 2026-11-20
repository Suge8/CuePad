#if os(iOS)
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// 按住一张卡 0.2 秒把它拎起来，一挪就拖走。系统的长按菜单要按住半秒：拎起来之后不挪、接着按到半秒，菜单照旧出来（这一下收回）；
/// 所以要拖的不用等菜单，要菜单的按住别动。拎起来没挪就松手仍是点按：按得慢的人照样点得开卡、按得动卡上的钮。
/// 比半秒短这么多仍不误触：手指落下就滑的归滚动（0.2 秒里挪出了容许范围，这里就不认了）。
/// 垫在那一列底下的一个空视图，手势挂在窗口上。
struct BoardLift: UIViewRepresentable {
    /// 挂着不看的页不认。
    let enabled: Bool
    /// 这一点上有没有拖得动的卡：没有就不认，空白处按住再滑照样是滚动。点都在窗口坐标里。
    let hits: (CGPoint) -> Bool
    /// 拎起来了为真。
    let began: (CGPoint) -> Bool
    let moved: (CGPoint) -> Void
    /// 松手为真；被系统收走（菜单出来、来电）为假。
    let ended: (Bool) -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.lift = self
        anchor.press.isEnabled = enabled
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) { anchor.press.view?.removeGestureRecognizer(anchor.press) }

    final class Anchor: UIView {
        var lift: BoardLift?
        let press = Press()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            press.anchor = self
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            press.view?.removeGestureRecognizer(press)
            window?.addGestureRecognizer(press)
        }

        /// 这一页盖在别的东西下面（推进去的页、弹出的面板）时手指落不到它身上，也不认。
        fileprivate func accepts(_ finger: UITouch, at point: CGPoint) -> Bool {
            var page: UIView = self
            while let above = page.superview, !(page.next is UIViewController) { page = above }
            return finger.view?.isDescendant(of: page) == true && lift?.hits(point) == true
        }
    }

    /// 只看着这根手指、自己数时间，从头到尾不"认出来"：认出来要等别的手势先失败——SwiftUI 管卡上点按的那一个、长按菜单都要别人等，
    /// 手指不动它们就不失败，拎起来的那一下会一直拖到松手才到（实测）。不认出来就挡不住别人，所以拎起来之后一挪开，
    /// 别的全当场取消（`cancel`）：滚动、点按、长按菜单与系统拖放，这一下归拖。
    /// 按够半秒的菜单先认出来时系统让它失败（`reset`）。
    final class Press: UIGestureRecognizer {
        fileprivate weak var anchor: Anchor?
        private var finger: UITouch?
        private var start = CGPoint.zero
        private var lifted = false
        private var claimed = false

        private static let hold: TimeInterval = 0.2
        /// 拎起来之前手指挪出这么远就不是按住（同系统长按的容许位移）；拎起来之后挪出 `slop` 算是在拖。
        private static let still: CGFloat = 10
        private static let slop: CGFloat = 4

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard finger == nil, touches.count == 1, let touch = touches.first else { return touches.forEach { ignore($0, for: event) } }
            // 落下时就看落在哪：按在卡上的钮上，它一变成按下的样子，这根手指就不再挂在哪个视图上了（实测）
            guard anchor?.accepts(touch, at: touch.location(in: nil)) == true else { return state = .failed }
            finger = touch
            start = touch.location(in: nil)
            perform(#selector(raise), with: nil, afterDelay: Self.hold)
        }

        @objc private func raise() {
            guard state == .possible, finger != nil else { return }
            // 各列各有一个，拖动的状态只有一份：没拎起来（另一根手指正拖着一张）就不跟，不然这根手指挪的、放下的是那一张
            guard anchor?.lift?.began(start) == true else { return state = .failed }
            lifted = true
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let finger, touches.contains(finger) else { return }
            let point = finger.location(in: nil), far = hypot(point.x - start.x, point.y - start.y)
            guard lifted else {
                if far > Self.still { state = .failed }
                return
            }
            if !claimed {
                // 没挪开之前不报位置：松手还算点按，报了的话挨着邻卡按一下、手一抖就排了序
                guard far > Self.slop else { return }
                claimed = true
                // 按名字认：这几个没有公开的类型。改了名认不出来时，拖得慢的那几次菜单照旧弹出来（它的容许位移比看上去大，实测每秒 27 点仍弹）。
                // 不看它们认到哪一步了：管长按菜单的那个按下不到 0.2 秒就已经开始，只取消还没开始的话菜单照弹、这一下被它收走（实测）
                cancel { other in
                    other is UIPanGestureRecognizer || other is UITapGestureRecognizer || Self.swiftUI(other)
                        || ["TouchDurationObserving", "DragLift"].contains { String(describing: type(of: other)).contains($0) }
                }
            }
            anchor?.lift?.moved(point)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let finger, touches.contains(finger) else { return }
            if lifted {
                lifted = false
                anchor?.lift?.ended(true)
            }
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

        /// 卡上的钮一按下 SwiftUI 就认出来了：让它挡住的话按在钮上拎不起卡，这一下落给系统的拖放（实测）。
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { !Self.swiftUI(other) }

        private static func swiftUI(_ other: UIGestureRecognizer) -> Bool { NSStringFromClass(type(of: other)).hasPrefix("SwiftUI.") }

        override func reset() {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            finger = nil
            claimed = false
            if lifted {
                lifted = false
                anchor?.lift?.ended(false)
            }
            super.reset()
        }

        /// 也在看这根手指的手势里，`which` 挑中的这一下不再认。手势识别器没有"让别人失败"的入口，关一下再开是它认的取消。
        private func cancel(_ which: (UIGestureRecognizer) -> Bool) {
            for other in finger?.gestureRecognizers ?? [] where !(other is Press) && other.isEnabled && which(other) {
                other.isEnabled = false
                other.isEnabled = true
            }
        }
    }
}
#endif
