#if os(macOS)
import AppKit
import Testing
@testable import CuePad

/// 主菜单"显示"里是开关浮层与侧栏的命令：搜索 ⌘K、任务 ⌘⇧T、侧栏 ⌃⌘S（macOS 标准的显示/隐藏侧栏）。放在主菜单而不是窗口里的快捷键：
/// 浮层开着时只有主菜单收得到。侧栏不用 ⌘\：常见的 1Password 把它占作全局快捷键，按键到不了 App。
@MainActor
struct MainMenuTests {
    @Test func 显示菜单里有搜索_任务_侧栏三个开关() {
        let items = MainMenu.build().items.first { $0.title == "显示" }?.submenu?.items ?? []
        let keys = items.map { [$0.title, $0.keyEquivalent] }
        #expect(keys == [["搜索", "k"], ["任务", "T"], ["侧栏", "s"]])
        #expect(items.map(\.keyEquivalentModifierMask) == [.command, .command, [.control, .command]])
    }
}
#endif
