#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// 滚动定位锚点。
enum ScrollAnchor {
    static let older = "older"
}

#if DEBUG
/// 视觉验收用的启动参数（只在 Debug 构建读取，配合 `CUEPAD_LIBRARY_DIR` 使用隔离资料库）：
/// - `-CuePadDemo YES`：库为空时写入演示数据；
/// - `-CuePadProject <名称>`：打开该项目；
/// - `-CuePadScene <collapsed|older|editor|search|tasks|trash|settings|menubar>`：初始画面；
/// - `-CuePadSearch <关键词>`：search 画面的预填关键词；`-CuePadCard <正文开头>`：editor 画面打开哪张卡；
/// - `-CuePadWindowSize 1280x800`：主窗口尺寸（内容铺满标题栏，即整窗尺寸）。
/// 设置项可在参数域覆盖：`-theme dark`；隔离 Pi 目录下隐藏"连接 Pi"提示：`-piExtensionDeclinedVersion '<integer>N</integer>'`（N 为随包扩展版本）。
/// `settings`、`menubar` 两个画面把对应窗口的内容放进主窗口拍（截图只截主窗口）。
@MainActor
enum DebugScene {
    private static var defaults: UserDefaults { .standard }
    static var scene: String? { defaults.string(forKey: "CuePadScene") }
    static var searchText: String { defaults.string(forKey: "CuePadSearch") ?? "" }

    static func prepare(_ workspace: Workspace) async {
        // 窗口在首帧之后才定下尺寸（窗口位置记忆、内容尺寸），这之后再改
        try? await Task.sleep(for: .milliseconds(100))
        resizeWindow()
        let store = workspace.services.store
        if defaults.bool(forKey: "CuePadDemo"), (try? await store.projects().isEmpty) == true {
            do { try await DemoLibrary.seed(store) } catch { workspace.fail(error) }
        }
        if let name = defaults.string(forKey: "CuePadProject"),
           let project = try? await store.projects().first(where: { $0.name == name }) {
            workspace.show(.project(project.id))
        }
        switch scene {
        case "collapsed": workspace.sidebar = .detailOnly
        case "search": workspace.overlay = .search
        case "tasks": workspace.overlay = .tasks
        case "trash": workspace.show(.trash)
        case "editor":
            let cards = (try? await store.cards(in: workspace.currentProject)) ?? []
            let prefix = defaults.string(forKey: "CuePadCard") ?? ""
            workspace.openCard = cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
        default: break
        }
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
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

/// `menubar` 画面：截图只截主窗口，所以把菜单栏面板放在桌面图上拍。
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
#endif
