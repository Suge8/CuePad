#if os(macOS)
import CueStore
import SwiftUI

/// 鼠标左键按下、松开在 AppKit 分发时就告诉工作区（本地事件监听，早于 SwiftUI 按钮识别按下）：点下的那一帧卡片就显出按下。
/// 只管本窗口的事件（监听是整个应用的）；不管 Control 加点击：它弹右键菜单，松开可能被菜单吞掉。
struct CardPressMonitor: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> MonitorView { MonitorView(workspace: workspace) }
    func updateNSView(_ view: MonitorView, context: Context) {}

    final class MonitorView: NSView {
        private let workspace: Workspace
        private var monitor: Any?
        private static let deleteKey: UInt16 = 51

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// ⌘⌫（同访达）删鼠标停着的那张卡：在文字里时照常是删到行首，批量选择时归底部的操作栏（`SelectionBar`）。
        /// 不挂成窗口级快捷键：那样会先于编辑页、输入栏接走 ⌘⌫。
        private func deleteHovered(_ event: NSEvent) -> Bool {
            guard event.keyCode == Self.deleteKey, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  !((window?.firstResponder as? NSTextView)?.isEditable ?? false),
                  let card = workspace.presses.deletable else { return false }
            workspace.attempt { try await self.workspace.trash(card) }
            return true
        }

        /// 窗口坐标（左下为原点）换成内容的坐标（左上为原点，内容铺满整窗）。
        private func flipped(_ point: NSPoint) -> CGPoint {
            CGPoint(x: point.x, y: (window?.contentView?.bounds.height ?? 0) - point.y)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return false }
                    if event.type == .keyDown { return self.deleteHovered(event) }
                    if event.type == .leftMouseDown { self.workspace.pressed(at: self.flipped(event.locationInWindow)) }
                    if !event.modifierFlags.contains(.control) { self.workspace.presses.mouse(down: event.type == .leftMouseDown) }
                    return false
                }
                return handled ? nil : event
            }
        }
    }
}
#endif
