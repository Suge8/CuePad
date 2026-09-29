#if os(macOS)
import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices?
    private var windowDelegate: MainWindowDelegate?
    private var statusItem: StatusItemController?
    private var menuBarPanel: MenuBarPanel?
    private var settingsWindow: SettingsWindowController?
    private var mainFrameKeeper: WindowFrameKeeper?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sigterm = TerminationSignal.install()
        let location: LibraryLocation
        do {
            location = try LibraryLocation.resolve()
        } catch {
            abortLaunch(error)
            return
        }
        MainMenu.install()
        let services = AppServices(location: location, defaults: location.makeDefaults(), mac: .live(bundleID: AppServices.bundleID))
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

        settingsWindow = SettingsWindowController(settings: services.settings) { RootViews.settings(services) }

        services.start()
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

    /// 配置有误时不能带着错误的位置去读写数据：说明原因后退出。
    private func abortLaunch(_ error: any Error) {
        Logger(subsystem: AppServices.bundleID, category: "launch").error("\(error.localizedDescription, privacy: .public)")
        FileHandle.standardError.write(Data("CuePad 无法启动：\(error.localizedDescription)\n".utf8))
        let alert = NSAlert(error: error)
        alert.messageText = "CuePad 无法启动"
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func makeMainWindow(_ services: AppServices) -> NSWindow {
        let window = MainWindowFactory.make(content: RootViews.mainWindow(services))
        let keeper = WindowFrameKeeper(window: window, name: "main", settings: services.settings)
        if !keeper.restore() { window.center() }
        mainFrameKeeper = keeper
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
