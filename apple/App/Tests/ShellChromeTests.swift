#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import CuePad

/// 收起动画进行中的宿主窗口：endSheet 只是发出请求，弹窗要等 `finishDismissal` 才算结束。
@MainActor
private final class SlowSheetWindow: NSWindow {
    private var pendingSheet: NSWindow? = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    private(set) var endRequested = false

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    }

    override var attachedSheet: NSWindow? { pendingSheet }
    override func endSheet(_ sheetWindow: NSWindow) { endRequested = true }

    func finishDismissal() {
        pendingSheet = nil
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: self)
    }
}

@MainActor
struct ShellChromeTests {
    /// `NSApp.terminate` 在弹窗还挂着时会拒绝退出（"blocked by modal sheet"），所以继续退出之前，
    /// 弹窗必须已经真正结束，而不是刚发出 endSheet。
    @Test func 弹窗真正结束之后才继续退出_含嵌套() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        let nested = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.orderFront(nil) // 弹窗只能挂在已显示的窗口上
        defer { window.orderOut(nil) }
        var ended: Set<String> = []
        window.beginSheet(sheet) { _ in ended.insert("sheet") }
        sheet.beginSheet(nested) { _ in ended.insert("nested") }
        #expect(window.attachedSheet === sheet)
        var proceeded = false
        var stillAttached: [String] = []

        CuePadApplication.dismissPresentations(in: [window]) {
            proceeded = true
            if window.attachedSheet != nil { stillAttached.append("sheet") }
            if sheet.attachedSheet != nil { stillAttached.append("nested") }
        }

        await eventually { proceeded }
        #expect(proceeded, "弹窗没有全部结束，退出一直没有继续")
        #expect(stillAttached.isEmpty, "继续退出时这些弹窗还挂着：\(stillAttached)")
        #expect(ended == ["sheet", "nested"])
    }

    @Test func 系统报告弹窗结束之前不继续退出() {
        let slow = SlowSheetWindow()
        var proceeded = false

        CuePadApplication.dismissPresentations(in: [slow]) { proceeded = true }

        #expect(slow.endRequested)
        #expect(!proceeded, "收起动画还没结束就继续退出，系统会以 blocked by modal sheet 拒绝")
        slow.finishDismissal()
        #expect(proceeded)
    }

    @Test func 没有弹窗时立即继续退出() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        var proceeded = false

        CuePadApplication.dismissPresentations(in: [window]) { proceeded = true }

        #expect(proceeded)
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
#endif
