#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// 点在这一块外面时交出键盘（这一块里的输入框拿着键盘时）。AppKit 点在不接焦点的地方（页面空白、卡片、纸面）不换第一响应者，
    /// 输入框一直拿着键盘，"失焦就收起、记下"永远等不来：出现即聚焦、失焦没写字就收回的输入行都挂它（`NewTaskField`、批注的 `NoteEditor`）。
    /// 只看按下、不吞事件：点到的东西照常响应，点到别的输入框照常接过键盘。
    func resignsFocusOnOutsideClick() -> some View { background { OutsideClick() } }
}

private struct OutsideClick: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.pressed(event) }
                return event
            }
        }

        isolated deinit { monitor.map(NSEvent.removeMonitor) }

        /// 键盘在这一块里（输入框的编辑器落在它的框里）、按下在它外面：交出键盘。
        private func pressed(_ event: NSEvent) {
            guard let window, event.window === window, let editor = window.firstResponder as? NSView, editor.window === window else { return }
            let box = convert(bounds, to: nil)
            guard box.intersects(editor.convert(editor.bounds, to: nil)), !box.contains(event.locationInWindow) else { return }
            window.makeFirstResponder(nil)
        }
    }
}
#endif
