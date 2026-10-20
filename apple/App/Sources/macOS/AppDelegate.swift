#if os(macOS)
import CueStore
import AppKit
import SwiftUI
import UserNotifications
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var services: AppServices?
    private var statusItem: StatusItemController?
    private var menuBarPanel: MenuBarPanel?
    private var cueBar: CueBar?
    private var settingsWindow: SettingsWindowController?
    private var mainFrameKeeper: WindowFrameKeeper?
    private var terminationSources: [any DispatchSourceProtocol] = []
    /// 资料库打不开时的失败页；重试成功即关掉。
    private var failureWindow: NSWindow?
    /// 主窗口的工作区（主菜单"显示"里的开关作用在它上面；主窗口本身是 `services.windowShell`）。
    private var workspace: Workspace?
    /// 系统通知：在启动完成前设为代理，冷启动时点开的通知才不会丢。
    private let alerts = AlertCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = alerts
        terminationSources = TerminationSignal.install()
        MainMenu.install()
        FirstClick.install()
        launch()
    }

    /// 解析资料库位置、打开资料库、建出主窗口与菜单栏部件。位置有误时说明原因后退出（不能带着错误的位置去读写）；
    /// 资料库打不开时不终止：显示失败页，"重试"重新走这里。
    private func launch() {
        let location: LibraryLocation
        do {
            location = try LibraryLocation.resolve()
        } catch {
            abortLaunch(error)
            return
        }
        let services: AppServices
        do {
            services = try AppServices(
                location: location, defaults: location.makeDefaults(), sync: DebugHooks.syncSource,
                mac: .live(location: location, alerts: alerts))
        } catch {
            showLibraryFailure(LibraryFailure(error, location: location))
            return
        }
        failureWindow?.close()
        failureWindow = nil
        let workspace = Workspace(services: services)
        Task { await workspace.follow() }
        let window = makeMainWindow(services, workspace: workspace)
        services.windowShell = window
        services.alerts = alerts
        alerts.services = services
        alerts.workspace = workspace
        followAlertTaps(workspace)
        self.services = services
        self.workspace = workspace

        let panel = MenuBarPanel()
        // 菜单栏面板点会话或 Cue：收起面板、把主窗口叫到前面，在它的内容区打开那一页（与侧栏同一处）
        panel.setContent(RootViews.menuBarPad(services, workspace: workspace) { [weak panel] route in
            panel?.hide()
            window.show()
            workspace.show(route)
        })
        menuBarPanel = panel
        statusItem = StatusItemController(
            togglePanel: {
                panel.toggle(below: $0)
                // 面板常驻、内容不重建：弹出时在这里看额度是否陈旧
                if panel.isVisible { Task { await services.refreshQuotaIfStale() } }
            },
            toggleWindow: { window.toggleFromMenu() })

        services.start()
        services.follow { await services.viewer?.follow(workspace) }
        let cueBar = CueBar(services: services, workspace: workspace)
        self.cueBar = cueBar
        settingsWindow = SettingsWindowController(cueName: { workspace.cue.name }) {
            RootViews.settings($0, services, cueBar: cueBar)
        }
        DebugHooks.present(window)
        // 首次打开请你接入检测到的 Agent（主窗口里的浮层），之后在设置里改；隔离库（开发与验收）不弹
        if !location.isIsolated { Task { await workspace.offerAgentSetup() } }
    }

    /// 点开的 Agent 通知（含冷启动时点的）：打开那个会话（主窗口已由 `AlertCenter.receive` 叫到前面）。
    private func followAlertTaps(_ workspace: Workspace) {
        let alerts = alerts
        Task { [weak workspace] in
            await alerts.refresh()
            for await _ in Observations({ alerts.pendingTap }) {
                guard let tap = alerts.consumeTap(), let workspace else { continue }
                await workspace.open(alert: tap)
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        services?.updates.checkForUpdates()
    }

    @objc func installUpdateNow(_ sender: Any?) {
        services?.updates.installNow()
    }

    /// 主菜单里写"等 N 个 Agent 做完再装"的那一行（停用，只是说明）。
    static let updateNoteTag = 1

    /// 主菜单"显示"里的搜索（⌘K）、任务面板（⌘⇧T）与侧栏（⌃⌘S）：命令本身是开关，开着时同一条命令把它关掉。放在主菜单而不是窗口里的快捷键：
    /// 模态浮层（⌘K 自己就是）开着时只把 ⌘ 组合键交给主菜单（`PanelHost`）。
    @objc func toggleSearch(_ sender: Any?) { workspace?.searching.toggle() }
    @objc func toggleTasks(_ sender: Any?) { workspace?.showsTasks.toggle() }
    /// 不叫 `toggleSidebar(_:)`：AppKit 的分栏控制器自己响应那个动作，在响应链上先接走，带着分栏动画开合。
    @objc func toggleCueSidebar(_ sender: Any?) { workspace?.pages.toggleSidebar() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(checkForUpdates(_:)): services?.updates.canCheckForUpdates ?? false
        case #selector(installUpdateNow(_:)): showsUpdateWait(item)
        // 资料库读不出来时：搜索结果能打开卡片、任务面板能增改任务，都是写入入口
        case #selector(toggleSearch(_:)), #selector(toggleTasks(_:)): workspace?.isLibraryReady == true && NSApp.mainWindow === services?.windowShell
        case #selector(toggleCueSidebar(_:)): NSApp.mainWindow === services?.windowShell
        default: true
        }
    }

    /// 更新在等后台会话做完时才显示这两行；说明那一行跟着等几个改字、一直停用。
    private func showsUpdateWait(_ item: NSMenuItem) -> Bool {
        let note = services?.updates.waitingNote
        item.isHidden = note == nil
        guard item.tag == Self.updateNoteTag else { return note != nil }
        item.title = note ?? ""
        return false
    }

    /// 发送者是 `SettingsPane` 时翻到那一页（`SettingsPane.open`），菜单与 ⌘, 停在上次那一页。
    @objc func showSettings(_ sender: Any?) {
        settingsWindow?.show(sender as? SettingsPane)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 通知权限可能在系统设置里改过
        Task { await alerts.refresh() }
        Task { await services?.handleActivation() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.windowShell?.show()
        failureWindow?.makeKeyAndOrderFront(nil)
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
        cueBar?.hotkey.unregister()
    }

    private func showLibraryFailure(_ failure: LibraryFailure) {
        Logger(subsystem: AppServices.bundleID, category: "launch").error("资料库没能打开：\(failure.reason, privacy: .public)")
        let content = UnreadableLibraryView(failure: failure) { [weak self] in self?.launch() }
            .frame(width: 520, height: 420)
            .modifier(PaletteProvider())
        let window: NSWindow
        if let failureWindow {
            window = failureWindow
            window.contentViewController = NSHostingController(rootView: content)
        } else {
            window = WindowFactory.utility(title: "CuePad", content: content)
            window.center()
            failureWindow = window
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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

    private func makeMainWindow(_ services: AppServices, workspace: Workspace) -> MainShellWindow {
        let window = WindowFactory.main(content: RootViews.mainWindow(services, workspace: workspace))
        // 屏幕外测量不记窗口位置：记下的屏幕外位置会让之后正常打开时窗口不见
        if DebugHooks.placesOffscreen(window) { return window }
        mainFrameKeeper = WindowFrameKeeper(window: window, name: "main", settings: services.settings)
        return window
    }
}

/// SIGTERM（与本机构建的父进程退出，`DebugHooks.exitsWithParent`）走正常退出流程，使快捷键与菜单栏图标被释放。
/// 信号在后台队列接收、再投到主线程 run loop 的 common modes：主队列在应用级模态面板运行时不被处理。
enum TerminationSignal {
    static func install() -> [any DispatchSourceProtocol] {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler(handler: terminateOnMainRunLoop)
        source.resume()
        return [source] + [DebugHooks.exitsWithParent(terminateOnMainRunLoop)].compactMap(\.self)
    }

    private static let terminateOnMainRunLoop: @Sendable () -> Void = {
        AppDelegate.onMainRunLoop { NSApp.terminate(nil) }
    }
}
#endif
