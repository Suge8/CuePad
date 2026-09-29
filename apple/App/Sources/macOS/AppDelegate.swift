#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var windowDelegate: MainWindowDelegate?
    private var statusItem: StatusItemController?
    private var menuBarPanel: MenuBarPanel?
    private var settingsWindow: SettingsWindowController?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        let services = AppServices()
        let window = makeMainWindow(services)
        let shell = WindowShell(window: window)
        let windowDelegate = MainWindowDelegate(shell: shell)
        window.delegate = windowDelegate
        services.windowShell = shell
        self.services = services
        self.windowDelegate = windowDelegate

        let panel = MenuBarPanel()
        panel.setContent(RootViews.menuBarPad(services))
        menuBarPanel = panel
        statusItem = StatusItemController(
            togglePanel: { panel.toggle(below: $0) },
            toggleWindow: { shell.toggleFromMenu() })

        settingsWindow = SettingsWindowController { RootViews.settings(services) }

        services.start()
        sigterm = TerminationSignal.install()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow?.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        services?.accessibility.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.windowShell?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.stop()
        statusItem?.remove()
    }

    private func makeMainWindow(_ services: AppServices) -> NSWindow {
        let window = MainWindowFactory.make(content: RootViews.mainWindow(services))
        if !window.setFrameUsingName("main") { window.center() }
        window.setFrameAutosaveName("main")
        return window
    }
}

/// SIGTERM 走正常退出流程，使快捷键与菜单栏图标被释放。
/// 信号在后台队列接收、再投到主线程 run loop 的 common modes：主队列在应用级模态面板运行时不被处理。
enum TerminationSignal {
    static func install() -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler(handler: terminateOnMainRunLoop)
        source.resume()
        return source
    }

    private static let terminateOnMainRunLoop: @Sendable () -> Void = {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        CFRunLoopWakeUp(loop)
    }
}
#endif
