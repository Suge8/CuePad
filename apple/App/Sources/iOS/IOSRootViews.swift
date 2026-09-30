#if os(iOS)
import SwiftUI

/// iOS/iPadOS 的界面接入点：每个窗口的根视图在这里创建，界面实现替换 `root` 即可。
/// 视图通过环境取得 `AppServices`（`@Environment(AppServices.self)`）与本窗口的 `SceneContext`。
@MainActor
enum IOSRootViews {
    static func root() -> some View {
        IOSRoot()
    }
}
#endif
