#if os(macOS) && DEBUG
import AppKit
import CueStore
import QuartzCore
import SwiftUI

extension DebugScene {
    static func prepare(_ workspace: Workspace) async {
        // 窗口在首帧之后才定下尺寸（窗口位置记忆、内容尺寸），这之后再改
        try? await Task.sleep(for: .milliseconds(100))
        resizeWindow()
        _ = await prepareLibrary(workspace)
        let sampleCue = defaults.double(forKey: "CuePadSampleCue")
        if sampleCue > 0 { Task { await askSample(after: .seconds(sampleCue), services: workspace.services) } }
        if defaults.string(forKey: "CuePadSidebar") == "hidden" { workspace.pages.sidebar = .detailOnly }
        switch scene {
        case "collapsed": workspace.pages.sidebar = .detailOnly
        case "search": workspace.searching = true
        case "tasks": workspace.showsTasks = true
        case "agentsetup": workspace.showsAgentSetup = true
        case "connected":
            await connectAgents(workspace.services)
            workspace.show(.agent)
        case "select":
            // 批量选择：选上本页前三条灵感
            try? await Task.sleep(for: .seconds(1))
            for id in workspace.presses.selectable.prefix(3) { workspace.presses.toggle(id) }
        case "task":
            // 本项目第一条没完成的顶层任务，在任务浮窗里打开
            let tasks = (try? await workspace.services.store.tasks(.inProgress, .todo).flatMap(\.tasks)) ?? []
            if let task = tasks.first(where: { $0.parentID == nil && $0.projectID == workspace.currentProject }) ?? tasks.first { workspace.open(task) }
        case "agent":
            if defaults.bool(forKey: "CuePadDemo") {
                await seedRemote(workspace.services)
                await seedCue(workspace.services)
            }
            workspace.show(.agent)
        case "projectagent":
            // 项目页（-CuePadProject）的 Agent 栏，演示会话与同名文件夹的会话都在；圆桌的任务下，发出去的提示词带发送状态
            if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
        case "cue", "cuememory", "cuerun":
            // Cue 页（演示数据见 `DebugScene+Cue.swift`）；cuememory 再打开"Cue 记得什么"，cuerun 打开"运行情况"（Cue 在这台值班时才有）
            if defaults.bool(forKey: "CuePadDemo") {
                await seedRemote(workspace.services)
                await seedCue(workspace.services)
            }
            workspace.show(.cue)
            if scene == "cuememory" { workspace.cue.showsMemory = true }
            if scene == "cuerun" { workspace.cue.showsRun = true }
        case "cuerows":
            await connectAgents(workspace.services)
            await seedCueRows(workspace.services)
            workspace.show(.agent)
        case "menubar", "cuebar":
            if defaults.bool(forKey: "CuePadDemo") {
                await seedRemote(workspace.services)
                await seedCue(workspace.services)
            }
        case "updatewait":
            // 更新在等后台会话做完再装：托管的会话由 socket 目录里的假扩展连上来（隔离的 CUEPAD_PI_SOCKET_DIR），连上后检查一次
            await connectAgents(workspace.services)
            let pi = workspace.services.pi
            let busy = { pi.sessions.contains { $0.hosted && $0.state.hasPendingWork } }
            if !busy() { for await _ in pi.changes() where busy() { break } }
            workspace.services.updates.checkForUpdates()
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            mainWindow?.animationBehavior = .none
            mainWindow?.orderOut(nil)
        case "settings":
            // 拍真的设置窗口（连同标题栏）：主窗口不带淡出地收起，截图脚本取到的就是它
            if defaults.bool(forKey: "CuePadDemo") {
                await seedRemote(workspace.services)
                await seedCue(workspace.services)
            }
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            mainWindow?.animationBehavior = .none
            mainWindow?.orderOut(nil)
        case "trash": workspace.show(.trash)
        case "archive": workspace.show(.archive)
        case "editor":
            // 散放的灵感进编辑页，提示词在它任务的浮窗里展开
            if let id = await card(in: workspace.currentProject, store: workspace.services.store),
               let card = try? await workspace.services.store.card(id) { workspace.open(card) }
        case "attach":
            guard let id = await card(in: workspace.currentProject, store: workspace.services.store),
                  let card = try? await workspace.services.store.card(id) else { break }
            workspace.open(card)
            try? await Task.sleep(for: .seconds(1))
            workspace.attaching = card
        case "session":
            // 整页打开 -CuePadSession（演示会话的 sessionID 与会话名相同）
            if defaults.bool(forKey: "CuePadDemo") {
                await seedRemote(workspace.services)
                await seedCue(workspace.services)
            }
            if let id = sessionToOpen {
                workspace.show(.session(id))
                if defaults.bool(forKey: "CuePadStream") { Task { await stream(id, store: workspace.services.store) } }
            }
        default: break
        }
        if defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(workspace.services) } }
        await presetSpeech(workspace)
        switch defaults.string(forKey: "CuePadBench") {
        case "churn": await benchChurn(workspace)
        case "interact": await InteractionBench.run(workspace)
        case "chatresize": Task { await ChatResizeBench.run() }
        case "chatscroll": Task { await ChatScrollBench.run() }
        default: break
        }
    }

    /// `-CuePadSampleCue`：Cue 请你允许一件事（算进"等你"），走 `CueService.followNotifications` 同一个出口。
    private static func askSample(after delay: Duration, services: AppServices) async {
        try? await Task.sleep(for: delay)
        guard let message = try? await services.store.addCueMessage(.cue, text: "登录页修好了，要推送到 origin/main 吗？", ask: .push),
              let alerts = services.alerts else { return }
        let content = CueAlert.content(name: try? await services.store.cueProfile()?.name, text: message.text, choices: message.choices, task: nil)
        guard !alerts.isWatchingCue else { return }
        await alerts.post(title: content.title, body: content.body)
    }

    /// connected：把几家 Agent 接进截图用的隔离目录（`xc.sh shot` 把各家的配置目录指到产物目录下），看接入后的侧栏、设置与 + 的新会话（选 Agent）。
    /// 配置目录建出来就算装着（没有命令时按目录认）。
    /// 演示用的更新器（`-CuePadScene updatewait`）：检查就当找到了更新、你点了安装，像 Sparkle 一样先问要不要推迟重启；装的那一刻只打一个点
    /// （`update-installed`），不真装。
    final class DemoUpdater: AppUpdater {
        var automaticallyChecksForUpdates = true
        var canCheckForUpdates = true
        var postponeRelaunch: ((@escaping () -> Void) -> Bool)?

        func checkForUpdates() {
            let install: () -> Void = { print("update-installed"); DebugHooks.mark("update-installed") }
            if postponeRelaunch?(install) != true { install() }
        }
    }

    private static func connectAgents(_ services: AppServices) async {
        for kind in AgentKind.allCases {
            try? FileManager.default.createDirectory(at: services.agents.home(kind), withIntermediateDirectories: true)
            await services.agents.detect(kind)
            try? await services.agents.install(kind)
        }
    }

    /// 布局反馈环的压力场景：数据持续变化（像首次启动导入）的同时，窗口宽度逐点扫过列数与目标栏的切换档位。
    /// 配合 `-AppleShowScrollBars Always`（滚动条占宽，内容高度一变可用宽度就变）最容易触发几何读数↔布局的循环；
    /// 出现循环时 SwiftUI 记 "Geometry action is cycling"，严重时 AppKit 因布局迭代超限抛异常退出。跑完自动退出。
    private static func benchChurn(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(1))
        guard let window = mainWindow else { return }
        let project = workspace.currentProject
        let widths = Array(stride(from: 900.0, through: 1500.0, by: 1))
        for (step, width) in widths.enumerated() {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
            if step.isMultiple(of: 4) {
                workspace.attempt { _ = try await workspace.createCard(body: "导入中 \(step)\n" + String(repeating: "正文", count: step % 40), in: project) }
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        NSApp.terminate(nil)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.resizable) && $0.styleMask.contains(.fullSizeContentView) }
    }

    /// 只调整主窗口尺寸，外框样式由壳层创建窗口时决定，这里不碰。
    private static func resizeWindow() {
        guard let value = defaults.string(forKey: "CuePadWindowSize") else { return }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = mainWindow else { return }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        if offscreen { placeOffscreen(window) } else { window.center() }
    }

    /// `-CuePadOffscreen YES`：主窗口放在所有屏幕之外，复现窗口不可见时的布局，测量时也不挡、不露在桌面上。
    static var offscreen: Bool { defaults.bool(forKey: "CuePadOffscreen") }

    /// 放到所有屏幕的左下方之外。要在窗口第一次显示之前调用，否则会先在屏幕中央闪一下。
    static func placeOffscreen(_ window: NSWindow) {
        let screens = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        window.setFrameOrigin(NSPoint(x: screens.minX - window.frame.width - 1000, y: screens.minY - window.frame.height - 1000))
    }
}

/// Debug 构建的主窗口：`-CuePadOffscreen` 时不让系统把窗口夹回屏幕内（默认会留一截在屏幕边上）。
final class DebugWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        DebugScene.offscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// `menubar` 画面：截图只截普通层级的窗口，菜单栏面板拍不到，所以把它放在桌面图上拍（`cuebar` 是"对 Cue 说"的输入条）。
struct DebugMenuBarStage: View {
    /// `cuebar` 画面：放"对 Cue 说"的输入条。
    var cueBar = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0xC98F5A), Color(hex: 0x3E5566)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            if cueBar { CueBarView(bar: nil).padding(.top, 120) } else { MenuBarPad().padding(.top, 40) }
        }
    }
}

/// 检测器自检用的刻意布局环（`-CuePadGeometryLoop YES`）：读自己的宽度，窄了就变宽、宽了又变窄，
/// 正是"几何读数回写影响自身排版的状态"。`scripts/layout-stress.sh --inject-loop` 靠它证明压力场景抓得到这类环。
struct GeometryLoopProbe: View {
    @State private var wide = false

    var body: some View {
        Color.clear
            .frame(width: wide ? 40 : 20, height: 1)
            .onGeometryChange(for: Bool.self) { $0.size.width < 30 } action: { wide = $0 }
            .accessibilityHidden(true)
    }
}
#endif
