#if os(macOS) && DEBUG
import AppKit
import SwiftUI

extension DebugScene {
    static func prepare(_ workspace: Workspace) async {
        // 窗口在首帧之后才定下尺寸（窗口位置记忆、内容尺寸），这之后再改
        try? await Task.sleep(for: .milliseconds(100))
        resizeWindow()
        _ = await prepareLibrary(workspace)
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
#endif
