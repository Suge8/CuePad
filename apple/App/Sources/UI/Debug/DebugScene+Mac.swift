#if os(macOS) && DEBUG
import AppKit
import CueStore
import SwiftUI

extension DebugScene {
    static func prepare(_ workspace: Workspace) async {
        // 窗口在首帧之后才定下尺寸（窗口位置记忆、内容尺寸），这之后再改
        try? await Task.sleep(for: .milliseconds(100))
        resizeWindow()
        let opened = await prepareLibrary(workspace)
        let sampleCue = defaults.double(forKey: "CuePadSampleCue")
        if sampleCue > 0 { Task { await askSample(after: .seconds(sampleCue), services: workspace.services) } }
        Task { await SyncBench.run(workspace) }
        Task { await cueNowTourIfAsked(workspace.cue) }
        if defaults.string(forKey: "CuePadSidebar") == "hidden" { workspace.pages.sidebar = .detailOnly }
        switch scene {
        case "collapsed": workspace.pages.sidebar = .detailOnly
        case "search": workspace.searching = true
        case "progress":
            // 进展页看板段：配 -CuePadDemo 时写入 Mac 同步来的演示会话与 Cue 的等你，推进中的任务带会话状态（同 iOS 的 progress）
            await seedDemo(workspace.services)
            if defaults.bool(forKey: "CuePadDemo") { await seedBusyBoard(workspace.services.store) }
            await seedCanvasSteps(workspace.services.store)
            workspace.show(.progress)
        case "agentsetup":
            // -CuePadConnected YES：几家先都接进隔离目录（同 connected），看接入面板的第二步（技能与规则收到一处）
            // Cue 在演示的 Mac Studio 上运行（这一台不用再启用），面板里没有要接、要启用的就是第二步；面板打开后自己再检测一遍，等它检测完再拍
            let connected = defaults.bool(forKey: "CuePadConnected")
            if connected {
                await connectAgents(workspace.services)
                await seedDemo(workspace.services)
                await workspace.recheckAgents()
            }
            workspace.showsSetup = true
            if connected { try? await Task.sleep(for: .seconds(3)) }
        case "connected":
            await connectAgents(workspace.services)
            await bindFolderIfAsked(workspace.services.store)
            workspace.showSessions()
        case "wallgap":
            // 卡片墙删卡后的排布：在当前项目（配 -CuePadProject Flow）新记两条，再删掉最早那条（它独占一列），看留下的几张怎么排
            try? await Task.sleep(for: .seconds(1))
            let project = workspace.currentProject ?? Project.defaultID
            for body in [String(localized: "报销\nbs 84.36 刀 claude github", table: "Demo"), String(localized: "产品决策\nanti-slop 整理前端", table: "Demo")] {
                _ = try? await workspace.createCard(body: body, in: project)
                try? await Task.sleep(for: .milliseconds(300))
            }
            try? await Task.sleep(for: .seconds(1))
            let cards = (try? await workspace.services.store.cards(in: project)) ?? []
            if let oldest = cards.filter({ !$0.isTask }).min(by: { $0.modifiedAt < $1.modifiedAt }) { try? await workspace.trash(oldest.id) }
        case "select":
            try? await Task.sleep(for: .seconds(1))
            for id in workspace.presses.selectable.prefix(3) { workspace.presses.toggle(id) }
        case "task":
            // 没给 -CuePadTask 时是本项目第一条没完成的顶层任务
            await openTask(workspace) { $0.parentID == nil && $0.projectID == workspace.currentProject }
        case "sessions":
            // 给了 -CuePadProject 先把项目范围设成它（同 iOS）
            await seedDemo(workspace.services)
            workspace.projectScope = opened
            workspace.showSessions()
        case "cue", "cuememory", "cueschedules", "cuerun":
            // Cue 页（演示数据见 `DebugScene+Cue.swift`）；cuememory 再打开"Cue 记得什么"，cuerun 打开"运行情况"（Cue 在这台值班时才有）
            await seedDemo(workspace.services)
            if defaults.bool(forKey: "CuePadNoAsks") { await settleAsks(workspace.services.store) }
            workspace.show(.cue)
            if scene == "cuememory" { workspace.cue.showsMemory = true }
            if scene == "cueschedules" { workspace.cue.showsSchedules = true }
            if scene == "cuerun" { workspace.cue.showsRun = true }
        case "cuerows":
            await connectAgents(workspace.services)
            await seedCueRows(workspace.services)
            workspace.showSessions()
        case "menubar", "cuebar":
            await seedDemo(workspace.services)
        case "updatewait":
            // 托管的 Pi 在干活时检查更新：它撑得过重启，更新不等它、直接装（演示更新器打一个点）。托管的会话由 socket 目录里的假扩展连上来
            // （隔离的 CUEPAD_PI_SOCKET_DIR），连上后检查一次；随 App 退出的那几家在干活时推迟、"等 N 个 Agent 做完再装"由 UpdateTests 证明
            await connectAgents(workspace.services)
            let pi = workspace.services.pi
            let busy = { pi.sessions.contains { $0.hosted && $0.state.hasPendingWork } }
            if !busy() { for await _ in pi.changes() where busy() { break } }
            workspace.services.updates.checkForUpdates()
            SettingsPane.open(.general)
            mainWindow?.animationBehavior = .none
            mainWindow?.orderOut(nil)
        case "settings":
            // 拍真的设置窗口（连同标题栏）：主窗口不带淡出地收起，截图脚本取到的就是它
            await seedDemo(workspace.services)
            SettingsPane.open(defaults.string(forKey: "CuePadSettingsPane").flatMap(SettingsPane.init(rawValue:)))
            mainWindow?.animationBehavior = .none
            mainWindow?.orderOut(nil)
        case "trash": workspace.show(.trash)
        case "archive": workspace.show(.archive)
        case "library", "instruction", "skill", "duplicate":
            // 技能与规则（配 -CuePadDemo YES 有演示的文件）；文件页同 iOS（`DemoAgentLibrary.file`），给了 -CuePadProject 的项目规则盖在项目页上
            if opened == nil || scene != "instruction" { workspace.show(.library) }
            workspace.libraryPane = DebugHooks.preset.libraryPane
            if let scene, let file = DemoAgentLibrary.file(scene: scene, project: opened) { workspace.openLibrary(file) }
        case "editor":
            if let id = await card(in: workspace.currentProject ?? Project.defaultID, store: workspace.services.store),
               let card = try? await workspace.services.store.card(id) { workspace.open(card) }
        case "session":
            // 整页打开 -CuePadSession（演示会话的 sessionID 与会话名相同）
            await seedDemo(workspace.services)
            if let id = sessionToOpen {
                workspace.show(.session(id))
                if defaults.bool(forKey: "CuePadStream") { Task { await stream(id, store: workspace.services.store) } }
            }
        default: break
        }
        if defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(workspace.services) } }
        if defaults.string(forKey: "CuePadSidebarCycle") != nil { Task { await cycleSidebar() } }
        await presetSpeech(workspace)
        switch defaults.string(forKey: "CuePadBench") {
        case "churn": await benchChurn(workspace)
        case "interact": await InteractionBench.run(workspace)
        case "chatscroll": Task { await ChatScrollBench.run() }
        default: break
        }
    }

    /// `-CuePadDemo YES` 时补上演示 Mac 的在线会话与 Cue 的对话（各自已写过就不再写）。
    private static func seedDemo(_ services: AppServices) async {
        guard defaults.bool(forKey: "CuePadDemo") else { return }
        await seedRemote(services)
        await seedCue(services)
    }

    /// `-CuePadSidebarCycle YES`（配录屏）：画面就绪后每 1.5 秒开合一次侧栏，走 ⌃⌘S 那条路（主菜单动作经响应链），看开合的动效。
    /// `-CuePadSidebarCycle fast`：动画中途反向——按下后 0.1 秒再按、0.06 秒连按三次，各停 1.5 秒，看打断时页是否仍贴着侧栏、停下时是否回到终点。
    private static func cycleSidebar() async {
        // 两次之间停多久是录屏的节奏，不是在等别的事
        let gaps: [Double] = defaults.string(forKey: "CuePadSidebarCycle") == "fast" ? [0.1, 1.5, 0.06, 0.06, 1.5] : [1.5]
        try? await Task.sleep(for: .seconds(1.5))
        var step = 0
        while !Task.isCancelled {
            NSApp.sendAction(#selector(AppDelegate.toggleCueSidebar(_:)), to: nil, from: nil)
            try? await Task.sleep(for: .seconds(gaps[step % gaps.count]))
            step += 1
        }
    }

    /// `-CuePadSampleCue`：Cue 请你允许一件事（算进"等你"）。隔离库里 Cue 不值班，替 `CueService.followNotifications` 交给同一个出口。
    private static func askSample(after delay: Duration, services: AppServices) async {
        try? await Task.sleep(for: delay)
        guard let message = try? await services.store.addCueMessage(.cue, text: String(localized: "登录页修好了，要推送到 origin/main 吗？", table: "Demo"), ask: try? CueAsking(.push, action: String(localized: "把登录页的修复推送到 origin/main", table: "Demo"))),
              let alerts = services.alerts else { return }
        let content = CueAlert.content(name: try? await services.store.cueProfile()?.name, text: message.text, asking: message.asking, choices: message.choices, looks: message.shots.map(\.look))
        await alerts.post(title: content.title, body: content.body)
    }

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

        func checkForUpdatesInBackground() { checkForUpdates() }
    }

    /// `-CuePadFolder <路径>`：建一个以文件夹命名、绑着它的项目（已有同名的不再建）。隔离实例里真跑 Cue 派活要有绑了文件夹的项目，
    /// 而系统的选文件夹面板读写正式版的偏好域（同一个 bundle id），在后台也点不动。
    private static func bindFolderIfAsked(_ store: CueStore) async {
        guard let path = defaults.string(forKey: "CuePadFolder") else { return }
        let name = URL(filePath: path).lastPathComponent
        guard (try? await store.projects())?.contains(where: { $0.name == name }) != true,
            let project = try? await store.createProject(name: name, color: "#2F4A9E", icon: ProjectIcon.globe.rawValue)
        else { return }
        try? await store.setDirectory(path, for: project.id)
    }

    /// connected：把几家 Agent 接进截图用的隔离目录（`xc.sh shot` 把各家的配置目录指到产物目录下），看接入后的侧栏、设置与 + 的新会话（选 Agent）。
    /// 配置目录建出来就算装着（没有命令时按目录认）。
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
        let project = workspace.currentProject ?? Project.defaultID
        let widths = Array(stride(from: 900.0, through: 1500.0, by: 1))
        for (step, width) in widths.enumerated() {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
            if step.isMultiple(of: 4) {
                workspace.attempt { _ = try await workspace.createCard(body: String(localized: "导入中 \(step)", table: "Demo") + "\n" + String(repeating: String(localized: "正文", table: "Demo"), count: step % 40), in: project) }
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        NSApp.terminate(nil)
    }

    /// 主窗口（Debug 里是 `DebugWindow`）。
    static var mainWindow: NSWindow? { NSApp.windows.first { $0 is DebugWindow } }

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
final class DebugWindow: MainShellWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        DebugScene.offscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// `newsession` 画面：新会话表单（平时从 + 弹出，+ 读这台 Mac 的 Agent 交给它）。配 `-CuePadDemo YES` 时读演示 Mac（demo-mac）的 Agent：
/// 隔离实例里这台一家都不能用，看不到选 Agent 与模型的那一排。
struct DebugNewSessionForm: View {
    @Environment(Workspace.self) private var workspace
    @State private var agents: MacAgents?

    var body: some View {
        let host = DebugScene.defaults.bool(forKey: "CuePadDemo") ? "demo-mac" : workspace.services.hostID
        NewSessionForm(agents: agents) { _ in }
            .observing(workspace.services.store, into: $agents) { try $0.macAgents(on: host) }
    }
}

/// `menubar` 画面：截图只截普通层级的窗口，菜单栏面板拍不到，所以把它放在桌面图上拍（`cuebar` 是"对 Cue 说"的输入条）。
struct DebugMenuBarStage: View {
    /// `cuebar` 画面：放"对 Cue 说"的输入条。
    var cueBar = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.79, green: 0.56, blue: 0.35), Color(red: 0.24, green: 0.33, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            // 窗口当屏幕：面板顶在上方、底下留边，窗口矮时同真面板一样"在做"在里面滚（`MenuBarPanel.maxHeight`）
            if cueBar { CueBarView(bar: nil).padding(.top, 120) } else { MenuBarPad().padding(.top, 40).padding(.bottom, 8) }
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
