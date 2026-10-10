#if os(macOS) && DEBUG
import AppKit
import QuartzCore
import SwiftUI

extension DebugScene {
    static func prepare(_ workspace: Workspace) async {
        // 窗口在首帧之后才定下尺寸（窗口位置记忆、内容尺寸），这之后再改
        try? await Task.sleep(for: .milliseconds(100))
        resizeWindow()
        _ = await prepareLibrary(workspace)
        if defaults.string(forKey: "CuePadSidebar") == "hidden" { workspace.sidebar = .detailOnly }
        switch scene {
        case "collapsed": workspace.sidebar = .detailOnly
        case "search": workspace.searching = true
        case "tasks": workspace.showsTasks = true
        case "task":
            // 本项目第一条没完成的顶层任务，整页打开
            let tasks = (try? await workspace.services.store.tasks(.inProgress, .todo).flatMap(\.tasks)) ?? []
            workspace.openCard = tasks.first { $0.parentID == nil && $0.projectID == workspace.currentProject }?.id ?? tasks.first?.id
        case "agent":
            if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
            workspace.show(.agent)
        case "projectagent":
            // 项目页（-CuePadProject）的 Agent 栏，演示会话与同名文件夹的会话都在
            if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
        case "trash": workspace.show(.trash)
        case "archive": workspace.show(.archive)
        case "editor": workspace.openCard = await card(in: workspace.currentProject, store: workspace.services.store)
        case "attach":
            guard let id = await card(in: workspace.currentProject, store: workspace.services.store) else { break }
            workspace.openCard = id
            try? await Task.sleep(for: .seconds(1))
            workspace.attaching = try? await workspace.services.store.card(id)
        case "session":
            // 整页打开 -CuePadSession（演示会话的 sessionID 与会话名相同）；-CuePadChatGrow YES 时之后每 4 秒进来一条回答，
            // -CuePadChatBulk <N> 时整批进来 N 轮长对话（同 iOS；右缘刻度滑条要 6 句以上你的话才出现）
            if defaults.bool(forKey: "CuePadDemo") { await seedRemote(workspace.services) }
            if let id = sessionToOpen { workspace.show(.session(id)) }
            if defaults.bool(forKey: "CuePadChatGrow"), let id = sessionToOpen {
                Task { await growChat(id, store: workspace.services.store) }
            }
            if let id = sessionToOpen, case let bulk = defaults.integer(forKey: "CuePadChatBulk"), bulk > 0 {
                Task { await bulkChat(id, count: bulk, store: workspace.services.store) }
            }
        default: break
        }
        switch defaults.string(forKey: "CuePadBench") {
        case "sidebar": await benchSidebar(workspace)
        case "motion": await benchMotion(workspace)
        case "resize": await benchResizeWhileToggling(workspace)
        case "churn": await benchChurn(workspace)
        case "perf": await PerfBench.run(workspace)
        case "agent": await PerfBench.agent(workspace)
        case "scenarios": await ScenarioBench.run(workspace)
        case "switch": await SwitchBench.run(workspace)
        case "press": await benchPress(workspace)
        default: break
        }
    }

    /// 动效连拍用：存一张新卡（看分列是否稳定、同列下移），再开合一张墙上的卡（看纸页沿原路放大与缩回）。
    private static func benchMotion(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(3))
        workspace.attempt { _ = try await workspace.createCard(body: "新记下的一条\n看看它落在哪一列", in: workspace.currentProject) }
        try? await Task.sleep(for: .seconds(2))
        workspace.openCard = await card(in: workspace.currentProject, store: workspace.services.store)
        try? await Task.sleep(for: .seconds(2))
        workspace.openCard = nil
        try? await Task.sleep(for: .seconds(2))
        NSApp.terminate(nil)
    }

    /// 按压连拍用（`-CuePadPressAt x,y`，窗口内左上角为原点的点，指向一张置顶卡）：在该点按下 250ms 后松开（打开卡片），
    /// 收起后再按下、拖到窗口外再松开（应回弹、不打开），最后像键盘那样直接打开这张卡，结束后退出。
    /// 每个事件打印主机时间（与 ScreenCaptureKit 帧时间同一时钟），连拍时据此对齐；第一次按下时在同一轮里亮出一个原生红块作对照。鼠标事件直接发给窗口，不动真实指针、不抢前台。
    private static func benchPress(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow, let view = window.contentView,
              let raw = defaults.string(forKey: "CuePadPressAt")?.split(separator: ","), raw.count == 2,
              let x = Double(raw[0]), let y = Double(raw[1])
        else { return NSApp.terminate(nil) }
        let point = NSPoint(x: x, y: view.bounds.height - y)
        func send(_ type: NSEvent.EventType, at location: NSPoint) {
            // 与 ScreenCaptureKit 帧时间同一时钟（主机时间），连拍时据此对齐
            print(String(format: "PRESS %@ %.1f", "\(type.rawValue)", CACurrentMediaTime() * 1000))
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            NSApp.postEvent(event, atStart: false)
        }
        // 合成事件产生不了真实的悬停（来自系统的鼠标跟踪）：替鼠标报一次停在这张卡上，真实点击前鼠标总是先停在卡上
        let pinned = try? await workspace.services.store.cards(in: workspace.currentProject).first(where: \.isPinned)
        if let pinned { workspace.hover(pinned.id, inside: true) }
        // 对照：按下的同一轮里改一个原生图层（随这一轮的隐式提交一起提交，与 SwiftUI 的改动同一时机），标出最早能出现变化的那一帧
        let marker = CALayer()
        marker.frame = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
        marker.backgroundColor = NSColor.systemRed.cgColor
        marker.isHidden = true
        view.layer?.addSublayer(marker)
        let reference = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            marker.isHidden = false
            return event
        }
        send(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(250))
        reference.map(NSEvent.removeMonitor)
        send(.leftMouseUp, at: point)
        marker.removeFromSuperlayer()
        try? await Task.sleep(for: .seconds(1.5))
        workspace.openCard = nil
        try? await Task.sleep(for: .seconds(1))
        send(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(250))
        let away = NSPoint(x: point.x, y: -200)
        send(.leftMouseDragged, at: away)
        send(.leftMouseUp, at: away)
        try? await Task.sleep(for: .seconds(1))
        // 键盘打开（↩、空格）不经过按下，直接打开：原卡片同样立即按下
        print(String(format: "PRESS key %.1f", CACurrentMediaTime() * 1000))
        workspace.openCard = pinned?.id
        try? await Task.sleep(for: .seconds(1.5))
        workspace.openCard = nil
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    /// 帧耗时测量用的固定负载：等界面稳定后开合侧栏 10 次（`PerfBench.sidebar`），打一行 `SIDEBAR {json}` 后退出；同时可由外部录制（Instruments 动画卡顿模板）。
    private static func benchSidebar(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(3))
        guard let view = mainWindow?.contentView else { return NSApp.terminate(nil) }
        let result = await PerfBench.sidebar(workspace, view: view)
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("SIDEBAR " + String(decoding: data, as: UTF8.self))
        NSApp.terminate(nil)
    }

    /// 页宽验收用：开合侧栏的动画进行中把窗口拉窄，停下后由外部截图看页面是否铺满详情区。
    private static func benchResizeWhileToggling(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(2))
        workspace.toggleSidebar()
        try? await Task.sleep(for: .milliseconds(60))
        guard let window = mainWindow else { return }
        var frame = window.frame
        frame.size.width -= 360
        window.setFrame(frame, display: true, animate: true)
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

/// `menubar` 画面：截图只截主窗口，所以把菜单栏面板放在桌面图上拍；`settings` 同理放设置窗口的内容。
struct DebugMenuBarStage: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0xC98F5A), Color(hex: 0x3E5566)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            MenuBarPad().padding(.top, 40)
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
