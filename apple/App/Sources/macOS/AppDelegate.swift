#if os(macOS)
import CueStore
import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var launched: Launch?
    private var services: AppServices? { launched?.services }
    private var statusItem: StatusItemController?
    private var menuBarPanel: MenuBarPanel?
    private var cueBar: CueBar?
    private var settingsWindow: SettingsWindowController?
    private var mainFrameKeeper: WindowFrameKeeper?
    private var terminationSources: [any DispatchSourceProtocol] = []
    private var failureWindow: NSWindow?
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

    private func launch() {
        let launched = Launch.make { [alerts] location in
            try AppServices(
                location: location, defaults: location.makeDefaults(), sync: DebugHooks.syncSource,
                mac: try .live(location: location, alerts: alerts))
        }
        self.launched = launched
        switch launched {
        case .ready(let services): start(services)
        case .failed(let failure): showLibraryFailure(failure)
        }
    }

    private func start(_ services: AppServices) {
        failureWindow?.close()
        failureWindow = nil
        services.syncing.connectSync()
        let workspace = Workspace(services: services)
        let window = makeMainWindow(services, workspace: workspace)
        services.windowShell = window
        services.alerts = alerts
        alerts.services = services
        alerts.workspace = workspace
        self.workspace = workspace
        let cueBar = CueBar(services: services, workspace: workspace)
        self.cueBar = cueBar
        settingsWindow = SettingsWindowController {
            SettingsView(pane: $0).environment(cueBar).panelHost().modifier(PaletteProvider()).environment(services)
        }
        window.present()
        Task {
            await NextFrame.drawn()
            startShell(services, workspace: workspace, window: window)
        }
    }

    private func startShell(_ services: AppServices, workspace: Workspace, window: MainShellWindow) {
        Task { await workspace.follow() }
        Task { await alerts.refresh() }
        let panel = MenuBarPanel()
        panel.setContent(MenuBarPad { [weak panel] route in
            panel?.hide()
            window.show()
            workspace.show(route)
        }.environment(workspace).modifier(PaletteProvider()).environment(services))
        menuBarPanel = panel
        statusItem = DebugHooks.scripted ? nil : StatusItemController(
            togglePanel: { panel.toggle(below: $0) },
            toggleWindow: { window.toggleFromMenu() })

        services.start()
        services.follow { await services.viewer.follow(workspace) }
        services.follow { await window.parkWhileUnseen(services) }
        services.follow { [alerts, statusItem] in
            for await tally in Observations({ workspace.cue.now.tally }) {
                statusItem?.show(tally)
                await alerts.showBadge(tally.needsYou)
            }
        }
        // 首次打开：接入检测到的 Agent 并启用 Cue（主窗口里的浮层）。从 Xcode 编出来直接打开的也弹（克隆仓库自己编的人，开发库就是他的库）；
        // 脚本起的实例（截图、录屏、测量）不弹，免得盖住要拍的画面，验收这一次时给 -CuePadOfferSetup
        if !DebugHooks.scripted || DebugHooks.args.offerSetup { workspace.offerSetup() }
        if let version = services.updates.updatedTo() { workspace.say("已更新到 CuePad \(version)") }
    }

    /// 菜单里的检查更新：在后台查，结果走提示；下好了侧栏底下出现更新钮，不弹窗。
    @objc func checkForUpdates(_ sender: Any?) {
        guard let services, let workspace else { return }
        Task {
            switch await services.updates.check() {
            case .found(let version) where services.updates.state != nil: workspace.say("CuePad \(version.name) 已下好，点侧栏底下的更新钮装")
            case .found(let version) where services.updates.automaticallyChecks: workspace.say("正在下载 CuePad \(version.name)")
            // 关了自动更新，Sparkle 不自己下（它的设置里自动下载跟着自动检查），这一版是要你点更新钮、在它的窗里装的
            case .found(let version): workspace.say("有新版 CuePad \(version.name)，点侧栏底下的更新钮装")
            case .latest: workspace.say("已是最新版本")
            case .failed(let error): workspace.say(Dotted(String(localized: "检查更新没成功：\(error)")), tone: .failure)
            case nil: workspace.say("正在检查更新")
            }
        }
    }

    @objc func toggleSearch(_ sender: Any?) { workspace?.searching.toggle() }
    @objc func showProgress(_ sender: Any?) {
        workspace?.searching = false
        workspace?.show(.progress)
    }
    @objc func newCard(_ sender: Any?) { workspace?.newCard() }
    @objc func newSession(_ sender: Any?) { workspace?.openNewSession() }
    @objc func toggleVoiceCall(_ sender: Any?) { workspace?.toggleVoiceCall() }
    /// 不叫 `toggleSidebar(_:)`：AppKit 的分栏控制器自己响应那个动作，在响应链上先接走，带着分栏动画开合。
    @objc func toggleCueSidebar(_ sender: Any?) {
        guard let workspace, let window = services?.windowShell else { return }
        workspace.toggleRail(WideMetrics(width: window.frame.width, workspace: workspace))
    }
    @objc func toggleCueColumn(_ sender: Any?) { workspace?.toggleCue() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(checkForUpdates(_:)): services?.updates.isAvailable == true
        case #selector(toggleSearch(_:)), #selector(showProgress(_:)), #selector(newCard(_:)), #selector(newSession(_:)):
            workspace?.isLibraryReady == true && NSApp.mainWindow === services?.windowShell
        case #selector(toggleCueSidebar(_:)), #selector(toggleCueColumn(_:)): NSApp.mainWindow === services?.windowShell
        default: true
        }
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow?.show(sender as? SettingsPane)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
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
        window.present(activating: true)
    }

    private func makeMainWindow(_ services: AppServices, workspace: Workspace) -> MainShellWindow {
        WindowFactory.main(content: MainRoot(workspace: workspace).environment(services)) { window in
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
