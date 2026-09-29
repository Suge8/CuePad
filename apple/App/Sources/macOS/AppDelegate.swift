#if os(macOS)
import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "shell")

    private var shell: WindowShell?
    private var windowDelegate: MainWindowDelegate?
    private var hotkey: GlobalHotkey?
    private var statusItem: StatusItemController?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        let window = makeMainWindow()
        let shell = WindowShell(window: window)
        let windowDelegate = MainWindowDelegate(shell: shell)
        window.delegate = windowDelegate
        self.shell = shell
        self.windowDelegate = windowDelegate

        let hotkey = GlobalHotkey(backend: CarbonHotkeyBackend()) { shell.toggleFromHotkey() }
        do {
            try hotkey.register(.optionSpace)
        } catch {
            Self.log.error("全局快捷键注册失败：\(String(describing: error), privacy: .public)")
        }
        self.hotkey = hotkey
        statusItem = StatusItemController { shell.toggleFromMenu() }

        installSigtermHandler()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shell?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.unregister()
        statusItem?.remove()
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CuePad"
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.contentViewController = NSHostingController(rootView: PlaceholderView())
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
