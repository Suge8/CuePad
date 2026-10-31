import SwiftUI

#if os(iOS)
/// SwiftUI 的 TapGesture.modifiers 只在 Mac 可用；iPad 从这一笔 UIKit 手势读取 ⌘，不另记键盘按下状态。
struct SessionTap: UIGestureRecognizerRepresentable {
    let action: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { UITapGestureRecognizer() }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action(recognizer.modifierFlags.contains(.command)) }
    }
}
#endif
