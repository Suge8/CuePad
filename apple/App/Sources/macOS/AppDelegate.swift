#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var windowDelegate: MainWindowDelegate?
    private var statusItem: StatusItemController?
    private var menuBarPanel: MenuBarPanel?
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

        services.start()
        installSigtermHandler()
        window.makeKeyAndOrderFront(nil)
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
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CuePad"
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.contentViewController = NSHostingController(rootView: RootViews.mainWindow(services))
        window.setContentSize(NSSize(width: 1200, height: 760)) // 须在设置 contentViewController 之后，否则被内容尺寸覆盖
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("main") { window.center() }
        window.setFrameAutosaveName("main")
        return window
    }

    /// SIGTERM 走正常退出流程，使快捷键与菜单栏图标被释放。
    private func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        sigterm = source
    }
}
#endif
