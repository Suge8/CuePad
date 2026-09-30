#if os(iOS)
import Foundation
import Observation

/// 一个窗口（场景）自己的状态。iPad 上多个窗口各选各的项目，所以不放进全局的 `AppSettings`；
/// 场景恢复由 `SceneRoot` 用 `@SceneStorage` 负责。
@MainActor @Observable
final class SceneContext {
    /// 该窗口当前选中的项目；nil 是收件箱。
    var currentProject: UUID?

    init(currentProject: UUID? = nil) {
        self.currentProject = currentProject
    }
}
#endif
