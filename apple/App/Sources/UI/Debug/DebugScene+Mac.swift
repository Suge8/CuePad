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
        if defaults.string(forKey: "CuePadBench") == "sidebar" { await benchSidebar(workspace) }
    }

    /// 帧耗时测量用的固定负载：等界面稳定后开合侧栏若干次，结束后退出，由外部录制（Instruments 动画卡顿模板）。
    private static func benchSidebar(_ workspace: Workspace) async {
        try? await Task.sleep(for: .seconds(3))
        for _ in 0..<10 {
            withAnimation { workspace.toggleSidebar() }
            try? await Task.sleep(for: .milliseconds(800))
        }
        NSApp.terminate(nil)
    }

    /// 只调整主窗口尺寸，外框样式由壳层创建窗口时决定，这里不碰。
    private static func resizeWindow() {
        guard let value = defaults.string(forKey: "CuePadWindowSize") else { return }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { return }
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
