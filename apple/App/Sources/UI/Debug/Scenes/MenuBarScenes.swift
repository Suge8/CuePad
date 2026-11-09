#if DEBUG && os(macOS)
import SwiftUI

extension DebugSceneEntry {
    /// 截图只截普通层级的窗口，菜单栏面板拍不到，所以放在桌面图上拍。
    static let menuBar = DebugSceneEntry("menubar", "cuebar", prepare: { workspace, _ in
        await DebugScene.seedDemo(workspace.services)
    }, stage: { workspace in
        AnyView(DebugMenuBarStage(cueBar: DebugScene.scene == "cuebar").environment(workspace))
    })
}
#endif
