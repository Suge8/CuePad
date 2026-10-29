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
        CueAtlas.shared.load()
        launch()
    }

    /// 解析资料库位置、打开资料库、建出主窗口并显示，画完第一帧再起其余的（`startShell`）。位置有误时说明原因后退出（不能带着错误的位置去读写）；
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
        services.connectSync()  // 第一拉不等建窗口
        let workspace = Workspace(services: services)
        let window = makeMainWindow(services, workspace: workspace)
        services.windowShell = window
        services.alerts = alerts
        alerts.services = services
        alerts.workspace = workspace
        self.services = services
        self.workspace = workspace
        // 设置与"对 Cue 说"在这里接好入口（窗口与内容第一次打开才建、才排，这里几乎不花时间）：设置随时可能被打开，不等第一帧之后
        let cueBar = CueBar(services: services, workspace: workspace)
        self.cueBar = cueBar
        settingsWindow = SettingsWindowController {
            SettingsView(pane: $0).environment(cueBar).panelHost().modifier(PaletteProvider()).environment(services)
        }
        DebugHooks.present(window)
        // 第一帧只有主窗口：工作区与服务的订阅、菜单栏图标与面板、后台服务都不在第一帧里，它们起头那一段同步的活（读库、注册、
        // 起各家的接入）排在第一帧之前就把窗口往后推。首屏要的数据已经当场读好（`Workspace.init`、`LiveSessions`、页面的 `observing`）
        Task {
            await NextFrame.drawn()
            startShell(services, workspace: workspace, window: window)
        }
    }

    /// 主窗口第一帧画完之后：工作区与服务开始跟着库，建菜单栏图标与面板，起后台服务。
    private func startShell(_ services: AppServices, workspace: Workspace, window: MainShellWindow) {
        Task { await workspace.follow() }
        Task { await alerts.refresh() }
        // 面板与主窗口共用 App 常驻的那个工作区（项目目录、会话归属与摘要只订阅一份，见 `Workspace.follow`）；点里面的一行在主窗口里打开那一页
        let panel = MenuBarPanel()
        panel.setContent(MenuBarPad { [weak panel] route in
            panel?.hide()
            window.show()
            workspace.show(route)
        }.environment(workspace).modifier(PaletteProvider()).environment(services))
        menuBarPanel = panel
        // 脚本起的实例（一天上百次）不建：那是用户菜单栏上的位置，每次起停都会闪一下
        statusItem = DebugHooks.scripted ? nil : StatusItemController(
            togglePanel: {
                panel.toggle(below: $0)
                // 面板常驻、内容不重建：弹出时在这里看额度是否陈旧
                if panel.isVisible { Task { await workspace.refreshQuota() } }
            },
            toggleWindow: { window.toggleFromMenu() })

        services.start()
        services.follow { await services.viewer?.follow(workspace) }
        services.follow { await window.parkWhileUnseen(services) }
        // Dock 与菜单栏图标的角标是要你管的几件（拍板加待回复）：读名牌的同一份（`CueNow.needsYou`），不另订阅库
        services.follow { [alerts, statusItem] in
            for await count in Observations({ workspace.cue.now.needsYou }) {
                statusItem?.show(badge: count)
                await alerts.showBadge(count)
            }
        }
        // 首次打开：接入检测到的 Agent 并启用 Cue（主窗口里的浮层）。从 Xcode 编出来直接打开的也弹（克隆仓库自己编的人，开发库就是他的库）；
        // 脚本起的实例（截图、录屏、测量）不弹，免得盖住要拍的画面，验收这一次时给 -CuePadOfferSetup
        if !DebugHooks.scripted || DebugHooks.offersSetup { workspace.offerSetup() }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        services?.updates.checkForUpdates()
    }

    @objc func installUpdateNow(_ sender: Any?) {
        services?.updates.installNow()
    }

    /// 主菜单里写"等 N 个 Agent 做完再装"的那一行（停用，只是说明）。
    static let updateNoteTag = 1

    /// 主菜单"显示"里的搜索（⌘K）、进展（⌘⇧T）与侧栏（⌃⌘S）：搜索与侧栏是开关，开着时同一条命令把它关掉；进展是去进展页（收起开着的搜索）。
    /// 放在主菜单而不是窗口里的快捷键：模态浮层（⌘K 自己就是）开着时只把 ⌘ 组合键交给主菜单（`PanelHost`）。
    @objc func toggleSearch(_ sender: Any?) { workspace?.searching.toggle() }
    @objc func showProgress(_ sender: Any?) {
        workspace?.searching = false
        workspace?.show(.progress)
    }
    @objc func newCard(_ sender: Any?) { workspace?.newCard() }
    @objc func newSession(_ sender: Any?) { workspace?.newSession() }
    /// 不叫 `toggleSidebar(_:)`：AppKit 的分栏控制器自己响应那个动作，在响应链上先接走，带着分栏动画开合。
    @objc func toggleCueSidebar(_ sender: Any?) { workspace?.pages.toggleSidebar() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(checkForUpdates(_:)): services?.updates.canCheckForUpdates ?? false
        case #selector(installUpdateNow(_:)): showsUpdateWait(item)
        // 资料库读不出来时：搜索结果能打开卡片、进展页能增改任务，都是写入入口
        case #selector(toggleSearch(_:)), #selector(showProgress(_:)), #selector(newCard(_:)), #selector(newSession(_:)):
            workspace?.isLibraryReady == true && NSApp.mainWindow === services?.windowShell
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
        DebugHooks.willTerminate()
    }

    private func showLibraryFailure(_ failure: LibraryFailure) {
        Logger(subsystem: AppIdentity.id, category: "launch").error("资料库没能打开：\(failure.reason, privacy: .public)")
        DebugHooks.libraryFailed(failure.reason)
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
        DebugHooks.present(window, activating: true)
    }

    /// 配置有误时不能带着错误的位置去读写数据：说明原因后退出。
    private func abortLaunch(_ error: any Error) {
        Logger(subsystem: AppIdentity.id, category: "launch").error("\(error.localizedDescription, privacy: .public)")
        FileHandle.standardError.write(Data("CuePad 无法启动：\(error.localizedDescription)\n".utf8))
        let alert = NSAlert(error: error)
        alert.messageText = String(localized: "CuePad 无法启动")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func makeMainWindow(_ services: AppServices, workspace: Workspace) -> MainShellWindow {
        WindowFactory.main(content: MainRoot(workspace: workspace).environment(services)) { window in
            // 屏幕外测量不记窗口位置：记下的屏幕外位置会让之后正常打开时窗口不见
            if DebugHooks.placesOffscreen(window) { return }
            mainFrameKeeper = WindowFrameKeeper(window: window, name: "main", settings: services.settings)
        }
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
