import CueStore
import Foundation

/// 去哪一页：Mac 内容区挂哪一页与 iOS 导航栈里推入哪一页是同一个类型，平台只差呈现（Mac 只用其中的 `project`、`unfiled`、`archive`、`trash`、`cue`、`agent`、`session`）。
nonisolated enum Route: Hashable {
    /// 项目书架：全部项目（iPhone、iPad 侧栏的"全部项目"）。
    case shelf
    case project(UUID)
    case unfiled
    /// 归档的灵感与任务。
    case archive
    case trash
    case settings
    case conflicts
    /// 跨项目的任务看板（iPhone、iPad 侧栏的"任务"）。
    case tasks
    /// Cue 页：和总控 Agent Cue 的对话（`CuePage`）。
    case cue
    /// Cue 的设置（手机从 Cue 面板推入，`CueSettingsScreen`；Mac 的在设置窗口里）。
    case cueSettings
    /// Agent 页：全部 Pi 会话（侧栏的"会话"）。
    case agent
    /// 一个项目的全部 Pi 会话（同 Agent 页，只列这个项目的）。
    case projectSessions(UUID)
    case search
    case card(UUID)
    /// 一个 Pi 会话的整页（近况与回复）。
    case session(SessionRoute)

    /// 会话页；`seed` 是推入前读好的这一页（iOS 的 `openSession`），通知跳转等只有记录 id 的入口不带。
    static func session(_ id: UUID, sessionID: String? = nil, seed: SessionDigest? = nil) -> Route {
        .session(SessionRoute(id: id, sessionID: sessionID, seed: seed))
    }

    /// 项目页，没有项目是未分类（通知与随手记的落点）。
    static func place(_ project: UUID?) -> Route { project.map(Route.project) ?? .unfiled }

    /// 从 Pi 的会话 id 去会话页（Mac 的侧栏、搜索、通知）。
    static func session(_ sessionID: String) -> Route { .session(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID) }
}

/// 会话页的路由：身份是会话记录 id（`PiSessionState.id`，由 Pi 的会话 id 算出，锁屏通知只带它）。`sessionID` 是 Pi 的会话 id
/// （Mac 的桥按它认在线的会话），只有记录 id 的入口不带。`seed` 是推入前读好的这一页，只作首帧
/// （标题、状态与最新的对话推入第一帧就在），之后一律以 Store 的观察流为准；两者都不参与相等。
nonisolated struct SessionRoute: Hashable {
    let id: UUID
    var sessionID: String?
    var seed: SessionDigest?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
