#if os(iOS) && DEBUG
import UIKit

/// `-CuePadAXDump YES`：界面起来 4 秒后把读屏看到的元素（标签、值、特征）按顺序写进资料库目录的
/// `ax-dump.txt`（行末是元素尺寸），给没有 UI 测试目标、没有 Simulator 图形界面时核对无障碍。自动化模式下 `accessibilityHidden` 的元素也会列出，
/// 所以多于读屏真读的；合并元素的标签（分隔点、图标名有没有混进去）才是读屏读到的。
extension DebugScene {
    static func dumpAccessibilityIfAsked() {
        guard defaults.bool(forKey: "CuePadAXDump"), let dir = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] else { return }
        // 和 XCTest 一样打开"自动化"无障碍：SwiftUI 只在有辅助技术时才建出元素树
        if let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(handle, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1)
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            var lines: [String] = []
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows where !window.isHidden { collect(window, into: &lines) }
            }
            try? lines.joined(separator: "\n").write(toFile: dir + "/ax-dump.txt", atomically: true, encoding: .utf8)
        }
    }

    private static func collect(_ node: NSObject, into lines: inout [String]) {
        if node.isAccessibilityElement {
            let traits = node.accessibilityTraits
            let kind = traits.contains(.button) ? "Button" : traits.contains(.header) ? "Header" : traits.contains(.staticText) ? "Text"
                : traits.contains(.image) ? "Image" : "Element"
            let value = node.accessibilityValue.map { " = \($0)" } ?? ""
            let size = node.accessibilityFrame.size
            lines.append("\(kind) '\(node.accessibilityLabel ?? "")'\(value) [\(Int(size.width))×\(Int(size.height))]")
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
