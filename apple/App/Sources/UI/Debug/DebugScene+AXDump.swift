#if os(iOS) && DEBUG
import UIKit

/// `-CuePadAXDump YES`：界面起来 4 秒后把读屏看到的元素（标签、值、特征）按顺序写进资料库目录的
/// `ax-dump.txt`（行末是元素尺寸），给没有 UI 测试目标、没有 Simulator 图形界面时核对无障碍。自动化模式下 `accessibilityHidden` 的元素也会列出，
/// 所以多于读屏真读的；合并元素的标签（分隔点、图标名有没有混进去）才是读屏读到的。
/// `-CuePadAXFocus YES`：旁白每落到一个元素就往资料库目录的 `ax-focus.txt` 追加一行（同上的格式，再带它在屏上的框）。读屏真走到哪、顺序与死循环以它为准：
/// 在模拟器里开旁白（`defaults write com.apple.Accessibility VoiceOverTouchEnabled`，验完关掉）、`axe swipe` 单指右扫一下走一格。
extension DebugScene {
    static func logAccessibilityFocusIfAsked() {
        guard args.driveOpts.axFocus, let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        Task {
            var lines: [String] = []
            for await note in NotificationCenter.default.notifications(named: UIAccessibility.elementFocusedNotification) {
                guard let element = note.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject else { continue }
                let frame = element.accessibilityFrame
                lines.append(describe(element) + " @\(Int(frame.minX)),\(Int(frame.minY))")
                await running("旁白焦点记录") { try lines.joined(separator: "\n").write(toFile: dir + "/ax-focus.txt", atomically: true, encoding: .utf8) }
            }
        }
    }

    static func dumpAccessibilityIfAsked() {
        guard args.driveOpts.axDump, let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        // 和 XCTest 一样打开"自动化"无障碍：SwiftUI 只在有辅助技术时才建出元素树
        if let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(handle, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1)
        }
        Task {
            await Task.wait(for: .seconds(4))
            var lines: [String] = []
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows where !window.isHidden { collect(window, into: &lines) }
            }
            await running("无障碍快照") { try lines.joined(separator: "\n").write(toFile: dir + "/ax-dump.txt", atomically: true, encoding: .utf8) }
        }
    }

    private static func describe(_ node: NSObject) -> String {
        let traits = node.accessibilityTraits
        let kind = traits.contains(.button) ? "Button" : traits.contains(.header) ? "Header" : traits.contains(.staticText) ? "Text"
            : traits.contains(.image) ? "Image" : "Element"
        let value = node.accessibilityValue.map { " = \($0)" } ?? ""
        let size = node.accessibilityFrame.size
        return "\(kind) '\(node.accessibilityLabel ?? "")'\(value) [\(Int(size.width))×\(Int(size.height))]"
    }

    private static func collect(_ node: NSObject, into lines: inout [String]) {
        if node.isAccessibilityElement {
            lines.append(describe(node))
            return
        }
        if let elements = node.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &lines) }
        } else if let view = node as? UIView {
            for sub in view.subviews where !sub.isHidden && sub.alpha > 0 { collect(sub, into: &lines) }
        }
    }
}
#endif
