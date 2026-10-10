#if os(macOS)
import AppKit
import Testing
@testable import CuePad

/// 主菜单"显示"里是开关浮层与侧栏的命令：搜索 ⌘K、任务 ⌘⇧T、侧栏 ⌘\。放在主菜单而不是窗口里的快捷键：浮层开着时只有主菜单收得到，
/// 中文输入法（实测微信输入法）下 ⌘\ 也到不了窗口里的快捷键。
@MainActor
struct MainMenuTests {
    @Test func 显示菜单里有搜索_任务_侧栏三个开关() {
        let items = MainMenu.build().items.first { $0.title == "显示" }?.submenu?.items ?? []
        let keys = items.map { [$0.title, $0.keyEquivalent] }
        #expect(keys == [["搜索", "k"], ["任务", "T"], ["侧栏", "\\"]])
        #expect(items.allSatisfy { $0.keyEquivalentModifierMask == .command })
    }
}
#endif
