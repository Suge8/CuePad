#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import CuePad

@MainActor
struct ShellChromeTests {
    @Test func 退出前结束所有挂在窗口上的弹窗_含嵌套() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        let nested = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.orderFront(nil) // 弹窗只能挂在已显示的窗口上
        defer { window.orderOut(nil) }
        var ended: Set<String> = []
        window.beginSheet(sheet) { _ in ended.insert("sheet") }
        sheet.beginSheet(nested) { _ in ended.insert("nested") }
        #expect(window.attachedSheet === sheet)

        CuePadApplication.dismissPresentations(in: [window])

        await eventually { ended == ["sheet", "nested"] }
        #expect(ended == ["sheet", "nested"], "弹窗没有全部结束：\(ended)")
    }

    @Test func 主菜单有设置项_快捷键是命令加逗号() throws {
        let app = try #require(MainMenu.build().items.first?.submenu)
        let item = try #require(app.items.first { $0.title == "设置…" })
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(AppDelegate.showSettings(_:)))
    }

    @Test func 主窗口创建时内容铺到透明标题栏下() {
        let window = MainWindowFactory.make(content: Color.clear)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
    }
}

@MainActor
struct MenuBarPanelSizingTests {
    @Observable @MainActor final class Height { var value: CGFloat = 120 }

    private struct Content: View {
        let height: Height
        // 高度有伸缩范围（像真实面板里随输入增长的文本框）：窗口不会被内容的最小/最大尺寸约束带着走，
        // 只能靠面板自己按固有尺寸调整。
        var body: some View { Color.clear.frame(width: 300, height: height.value).frame(minHeight: 40, maxHeight: .infinity) }
    }

    @Test func 内容变高变矮时面板跟着变_顶边留在图标下方() async throws {
        let screen = try #require(NSScreen.main).visibleFrame
        let anchor = CGRect(x: screen.midX, y: screen.maxY, width: 30, height: 25)
        let height = Height()
        let panel = MenuBarPanel()
        panel.setContent(Content(height: height))
        panel.show(below: anchor)
        defer { panel.hide() }
        await eventually { panel.frame.height == 120 }
        let top = panel.frame.maxY

        height.value = 220
        await eventually { panel.frame.height == 220 }
        #expect(panel.frame.height == 220)
        #expect(panel.frame.maxY == top)

        height.value = 90
        await eventually { panel.frame.height == 90 }
        #expect(panel.frame.height == 90)
        #expect(panel.frame.maxY == top)
    }
}

/// 没有事件可订阅的系统异步（窗口结束弹窗、布局后改尺寸）：有界条件等待。
@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}
#endif
