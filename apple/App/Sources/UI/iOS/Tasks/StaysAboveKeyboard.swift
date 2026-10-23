#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// 写着的时候整块留在键盘上方、离它一段空（看板里的回答框）：接过键盘时、每次长高时，让所在的竖向滚动区把它滚进来。
    /// 系统的避让只在接过键盘那一下把光标那一行贴着键盘上沿摆，框的下沿与发送钮被键盘的圆角盖住一截，写成几行长高后更是压在键盘下面（实测）。
    func staysAboveKeyboard(while active: Bool, text: String) -> some View {
        background { KeyboardReveal(active: active, text: text) }
    }
}

private struct KeyboardReveal: UIViewRepresentable {
    let active: Bool
    let text: String

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.active = active
        // 字变了（可能长了一行）：等这一轮排完再滚
        if active, probe.text != text { DispatchQueue.main.async { probe.reveal() } }
        probe.text = text
    }

    final class Probe: UIView {
        var active = false
        var text: String?
        private var observer: (any NSObjectProtocol)?
        /// 键盘上沿（屏幕坐标，同窗口坐标）；收着为 nil。
        private var keyboardTop: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            // 键盘升起（或换高）的动画走完、滚动区按键盘让完之后再摆一次
            observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated {
                    guard let self, let end else { return }
                    self.keyboardTop = end.minY < (self.window?.bounds.maxY ?? .infinity) ? end.minY : nil
                    if self.active { self.reveal() }
                }
            }
        }

        required init?(coder: NSCoder) { nil }

        isolated deinit { observer.map(NotificationCenter.default.removeObserver) }

        func reveal() {
            // 键盘上沿以上才算看得见：滚动区自己未必按键盘缩了框
            guard let window, let keyboardTop, let scroll = sequence(first: self as UIView, next: { $0.superview }).compactMap({ $0 as? UIScrollView }).first else { return }
            let box = convert(bounds, to: window)
            let overlap = box.maxY + Self.margin - keyboardTop
            guard overlap > 0 else { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + overlap), animated: true)
        }

        /// 框下沿离键盘上沿留多远。
        private static let margin: CGFloat = 12
    }
}
#endif
