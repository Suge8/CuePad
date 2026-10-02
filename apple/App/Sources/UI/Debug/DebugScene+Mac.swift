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
        // 像首次启动那样在界面起来之后导入旧版（Electron）资料库副本：项目页数据边导边变
        if let path = defaults.string(forKey: "CuePadImport") {
            do { _ = try await workspace.services.store.importElectronLibrary(from: URL(filePath: path)) } catch { workspace.fail(error) }
        }
        switch scene {
        case "collapsed": workspace.sidebar = .detailOnly
        case "search": workspace.overlay = .search
        case "tasks": workspace.overlay = .tasks
        case "trash": workspace.show(.trash)
        case "editor": workspace.openCard = await card(in: workspace.currentProject, store: workspace.services.store)
        default: break
        }
        switch defaults.string(forKey: "CuePadBench") {
        case "sidebar": await benchSidebar(workspace)
        case "motion": await benchMotion(workspace)
        case "resize": await benchResizeWhileToggling(workspace)
        case "churn": await benchChurn(workspace)
        case "perf": await PerfBench.run(workspace)
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
    /// 每个事件打印主机时间（与 ScreenCaptureKit 帧时间同一时钟），连拍时据此对齐。鼠标事件直接发给窗口，不动真实指针、不抢前台。
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
        send(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(250))
        send(.leftMouseUp, at: point)
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
        let pinned = try? await workspace.services.store.cards(in: workspace.currentProject).first(where: \.isPinned)
        print(String(format: "PRESS key %.1f", CACurrentMediaTime() * 1000))
        workspace.openCard = pinned?.id
        try? await Task.sleep(for: .seconds(1.5))
        workspace.openCard = nil
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    /// 帧耗时测量用的固定负载：等界面稳定后开合侧栏若干次，结束后退出，由外部录制（Instruments 动画卡顿模板）。
    private static func benchSidebar(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(3))
        for _ in 0..<10 {
            workspace.toggleSidebar()
            try? await Task.sleep(for: .milliseconds(800))
        }
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
        window.center()
        // 窗口放到给定位置（可以在屏幕外），复现窗口不可见时的布局
        let origin = (defaults.string(forKey: "CuePadWindowOrigin") ?? "").split(separator: ",").compactMap { Double($0) }
        if origin.count == 2 { window.setFrameOrigin(NSPoint(x: origin[0], y: origin[1])) }
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
