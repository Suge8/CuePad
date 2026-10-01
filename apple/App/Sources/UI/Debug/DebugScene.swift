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
/// - `-CuePadScene <画面>`：初始画面。Mac：collapsed、older、editor、search、tasks、trash、settings、menubar；
///   iOS 见 `DebugScene+iOS.swift`；
/// - `-CuePadSearch <关键词>`：search 画面的预填关键词；`-CuePadCard <正文开头>`：editor 画面打开哪张卡；
/// - `-CuePadWindowSize 1280x800`（仅 Mac）：主窗口尺寸（内容铺满标题栏，即整窗尺寸）；
/// - `-CuePadBench <sidebar|motion|resize|churn>`（仅 Mac）：开合侧栏 10 次 / 存卡后开合纸页（都在结束后退出，给 Instruments 或连拍取帧）；
///   resize 在侧栏开合途中拉窄窗口后停住，给截图核对页宽；churn 边加卡边逐点拉宽窗口，查布局反馈环（结束后退出）；
/// - `-CuePadWindowOrigin x,y`（仅 Mac）：窗口放到该位置，可在屏幕外；
/// - `-CuePadImport <cuepad.db 路径>`（仅 Mac）：界面起来后导入一份旧版资料库，复现首次启动边导边变。
/// 设置项可在参数域覆盖：`-theme dark`；Mac 隔离 Pi 目录下隐藏"连接 Pi"提示：`-piExtensionDeclinedVersion '<integer>N</integer>'`（N 为随包扩展版本）。
@MainActor
enum DebugScene {
    static var defaults: UserDefaults { .standard }
    static var scene: String? { defaults.string(forKey: "CuePadScene") }
    static var searchText: String { defaults.string(forKey: "CuePadSearch") ?? "" }

    /// 需要时写入演示数据，并按参数选中项目；返回选中的项目。
    static func prepareLibrary(_ workspace: Workspace) async -> UUID? {
        let store = workspace.services.store
        if defaults.bool(forKey: "CuePadDemo"), (try? await store.projects().isEmpty) == true {
            do { try await DemoLibrary.seed(store) } catch { workspace.fail(error) }
        }
        guard let name = defaults.string(forKey: "CuePadProject"),
              let project = try? await store.projects().first(where: { $0.name == name })
        else { return nil }
        workspace.show(.project(project.id))
        return project.id
    }

    /// `-CuePadCard` 指定（或最近修改）的一张卡。
    static func card(in project: UUID?, store: CueStore) async -> UUID? {
        let cards = (try? await store.cards(in: project)) ?? []
        let prefix = defaults.string(forKey: "CuePadCard") ?? ""
        return cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
    }
}
#endif
