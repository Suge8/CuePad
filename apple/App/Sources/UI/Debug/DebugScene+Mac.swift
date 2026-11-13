#if os(macOS) && DEBUG
import AppKit
import CueBridge
import CueStore
import SwiftUI

extension DebugScene {
    static func prepare(_ workspace: Workspace) async {
        // 窗口在首帧之后才定下尺寸（窗口位置记忆、内容尺寸），这之后再改
        await Task.wait(for: .milliseconds(100))
        resizeWindow()
        let opened = await prepareLibrary(workspace)
        let sampleCue = args.sampleCue
        if sampleCue > 0 { Task { await askSample(after: .seconds(sampleCue), services: workspace.services) } }
        Task { await SyncBench.run(workspace) }
        Task { await voiceCallIfAsked(workspace) }
        Task { await cueNowTourIfAsked(workspace) }
        presetColumns(workspace.services.settings)
        if let prepare = entry?.prepare { await running("摆画面") { try await prepare(workspace, opened) } }
        if let beside = args.layoutOpts.beside {
            workspace.openSession(SessionState.recordID(sessionID: beside), sessionID: beside, in: .beside)
        }
        if args.demoMac { Task { await runDemoMac(workspace.services) } }
        presetDrawers(workspace)
        if let pace = args.layoutOpts.sidebarCycle { Task { await cycle(#selector(AppDelegate.toggleCueSidebar(_:)), fast: pace == "fast") } }
        if let pace = args.layoutOpts.rightCycle { Task { await cycle(#selector(AppDelegate.toggleCueColumn(_:)), fast: pace == "fast") } }
        await reverseWideIfAsked(workspace)
        await presetSpeech(workspace)
        await voiceLayoutIfAsked(workspace)
        switch args.driveOpts.bench {
        case "churn": await benchChurn(workspace)
        case "interact": await InteractionBench.run(workspace)
        case "chatscroll": Task { await ChatScrollBench.run() }
        default: break
        }
    }

    static func seedDemo(_ services: AppServices) async {
        guard args.demo else { return }
        await seedRemote(services)
        await seedCue(services)
    }

    private static func cycle(_ action: Selector, fast: Bool) async {
        // 两次之间停多久是录屏的节奏，不是在等别的事
        let gaps: [Double] = fast ? [0.1, 1.5, 0.06, 0.06, 1.5] : [1.5]
        await Task.wait(for: .seconds(1.5))
        var step = 0
        while !Task.isCancelled {
            NSApp.sendAction(action, to: nil, from: nil)
            await Task.wait(for: .seconds(gaps[step % gaps.count]))
            step += 1
        }
    }

    /// 隔离库里 Cue 不值班，替 `CueService.followNotifications` 交给同一个出口。
    private static func askSample(after delay: Duration, services: AppServices) async {
        await Task.wait(for: delay)
        await running("Cue 请你允许一件事") {
            let message = try await services.store.addCueMessage(.cue, text: String(localized: "登录页修好了，要推送到 origin/main 吗？", table: "Demo"), ask: CueAsking(.push, action: String(localized: "把登录页的修复推送到 origin/main", table: "Demo")))
            guard let alerts = services.alerts else { return }
            let content = CueAlert.content(name: try await services.store.cueProfile()?.name, text: message.text, asking: message.asking, choices: message.choices, looks: message.shots.map(\.look))
            await alerts.post(title: content.title, body: content.body)
        }
    }

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

    /// 隔离实例里真跑 Cue 派活要有绑了文件夹的项目，而系统的选文件夹面板读写正式版的偏好域（同一个 bundle id），在后台也点不动。
    static func bindFolderIfAsked(_ store: CueStore) async {
        guard let path = args.folder else { return }
        let name = URL(filePath: path).lastPathComponent
        await running("绑文件夹的项目") {
            guard try await !store.projects().contains(where: { $0.name == name }) else { return }
            let project = try await store.createProject(name: name, color: "#2F4A9E", icon: ProjectIcon.globe.rawValue)
            try await store.setDirectory(path, for: project.id)
        }
    }

    /// 把几家 Agent 接进截图用的隔离目录（`xc.sh shot` 把各家的配置目录指到产物目录下）。配置目录建出来就算装着（没有命令时按目录认）。
    static func connectAgents(_ services: AppServices) async {
        await running("接入各家 Agent") {
            for kind in AgentKind.allCases {
                try FileManager.default.createDirectory(at: services.agents.home(kind), withIntermediateDirectories: true)
                await services.agents.detect(kind)
                do {
                    try await services.agents.install(kind)
                } catch AgentInstallError.isolated {
                    continue  // 隔离环境没给这家指配置目录：本机构建不改真实配置，这家不接入
                }
            }
        }
    }

    /// 布局反馈环的压力场景：数据持续变化（像首次启动导入）的同时，窗口宽度逐点扫过列数与目标栏的切换档位。
    /// 配合 `-AppleShowScrollBars Always`（滚动条占宽，内容高度一变可用宽度就变）最容易触发几何读数↔布局的循环；
    /// 出现循环时 SwiftUI 记 "Geometry action is cycling"，严重时 AppKit 因布局迭代超限抛异常退出。跑完自动退出。
    private static func benchChurn(_ workspace: Workspace) async {
        await Task.wait(for: .seconds(1))
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
            await Task.wait(for: .milliseconds(15))
        }
        NSApp.terminate(nil)
    }

    static var mainWindow: NSWindow? { NSApp.windows.first { $0 is DebugWindow } }

    /// 只调整主窗口尺寸，外框样式由壳层创建窗口时决定，这里不碰。
    private static func resizeWindow() {
        guard let size = windowSize, let window = mainWindow else { return }
        window.setContentSize(size)
        if offscreen { placeOffscreen(window) } else { window.center() }
    }

    static var offscreen: Bool { args.layoutOpts.offscreen }

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

/// `menubar` 画面：截图只截普通层级的窗口，菜单栏面板拍不到，所以把它放在桌面图上拍（`cuebar` 是"对 Cue 说"的输入条）。
struct DebugMenuBarStage: View {
    var cueBar = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.79, green: 0.56, blue: 0.35), Color(red: 0.24, green: 0.33, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
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
