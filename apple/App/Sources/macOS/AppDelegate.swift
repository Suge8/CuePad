#if os(macOS)
import CueStore
import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
        let services = AppServices(
            location: location, defaults: location.makeDefaults(), sync: .iCloud,
            mac: .live(bundleID: AppServices.bundleID, location: location))
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
        if !location.isIsolated { Task { await offerCommandLineTool(services) } }
    }

    /// 首次启动提示一次：装了就不打扰；位置被占用等情况在设置里看。
    private func offerCommandLineTool(_ services: AppServices) async {
        guard !services.settings.commandLineToolPrompted else { return }
        services.settings.commandLineToolPrompted = true
        let tool = services.commandLineTool
        await tool.refresh()
        guard tool.state == .notInstalled else { return }
        let alert = NSAlert()
        alert.messageText = "把 cuepad 命令行装进 PATH？"
        alert.informativeText = "装好后 agent 可以在 bash 里直接用 cuepad 读写你的卡片和任务。会在 ~/.local/bin/cuepad 建一个指向 App 的链接，不需要管理员权限，随时可在设置里卸载。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "以后再说")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await tool.install()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        services?.updates.checkForUpdates()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? services?.updates.canCheckForUpdates ?? false : true
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow?.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        services?.accessibility.refresh()
        Task { await services?.handleActivation() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.windowShell?.show()
        return true
    }

    /// 服务的收尾要等 actor 完成：先回复"稍后"，收尾结束再放行退出。terminate 可能是在主线程上的任务里调用的，
    /// 此时系统在嵌套的事件循环（模态面板模式）里等回复、主线程上排队的任务轮不到：等待放在主线程之外，
    /// 回复经主 run loop 的 common modes 送达（与 SIGTERM 同一条路），不依赖主线程上的任务。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        let finish = services.beginShutdown()
        Task.detached {
            _ = await finish()
            Self.onMainRunLoop { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// 在主 run loop 的 common modes 里执行（含模态面板模式），不经主队列。
    nonisolated static func onMainRunLoop(_ body: @escaping @MainActor () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated(body) }
        CFRunLoopWakeUp(loop)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        AppDelegate.onMainRunLoop { NSApp.terminate(nil) }
    }
}
#endif
