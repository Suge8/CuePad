import Foundation

/// 去哪一页：Mac 内容区挂哪一页与 iOS 导航栈里推入哪一页是同一个类型，平台只差呈现（Mac 只用其中的 `project`、`inbox`、`archive`、`trash`、`agent`、`session`）。
nonisolated enum Route: Hashable {
    /// 项目书架（iPhone 灵感标签的根；iPad 侧栏的"灵感"）。
    case shelf
    case project(UUID)
    case inbox
    /// 归档的灵感与任务。
    case archive
    case trash
    case settings
    case conflicts
    /// 跨项目的任务看板（书架上一行入口、iPad 侧栏进入）。
    case tasks
    /// Agent 页：全部 Pi 会话。
    case agent
    /// 一个项目的全部 Pi 会话（同 Agent 页，只列这个项目的）。
    case projectSessions(UUID)
    case search
    case card(UUID)
    /// 一个 Pi 会话的整页（近况与回复）。
    case session(SessionRoute)

    /// 会话页；`seed` 是推入前读好的这一页（iOS 的 `openSession`），通知跳转等只有 id 的入口不带。
    static func session(_ sessionID: String, seed: SessionDigest? = nil) -> Route { .session(SessionRoute(sessionID: sessionID, seed: seed)) }
}

/// 会话页的路由：身份只是 Pi 自己的会话 id。`seed` 是推入前读好的这一页，只作首帧
/// （标题、状态与最新的对话推入第一帧就在），之后一律以 Store 的观察流为准；不参与相等。
nonisolated struct SessionRoute: Hashable {
    let sessionID: String
    var seed: SessionDigest?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.sessionID == rhs.sessionID }
    func hash(into hasher: inout Hasher) { hasher.combine(sessionID) }
}
