import CueStore
import Foundation

/// 去哪一页：Mac 内容区挂哪一页与 iOS 导航栈里推入哪一页是同一个类型，平台只差呈现（Mac 只用其中的 `project`、`archive`、`trash`、`tasks`、`cue`、`agent`、`session`）。
nonisolated enum Route: Hashable {
    /// 项目书架：全部项目（iPhone、iPad 侧栏的"全部项目"）。
    case shelf
    case project(UUID)
    /// 归档的灵感与任务。
    case archive
    case trash
    case settings
    case conflicts
    /// 跨项目的任务看板（侧栏与 iPhone 底部的"任务"）。
    case tasks
    /// Cue 页：和总控 Agent Cue 的对话（`CuePage`）。
    case cue
    /// Cue 的设置（手机从 Cue 面板推入，`CueSettingsScreen`；Mac 的在设置窗口里）。
    case cueSettings
    /// Agent 页：全部 Pi 会话（iPhone 底部与 iPad 侧栏的"会话"）。
    case agent
    case search
    case card(UUID)
    /// 一个 Pi 会话的整页（近况与回复）。
    case session(SessionRoute)

    /// 打开 App 没有要回去的项目时（第一次打开、上次的项目进了回收站）落在哪：Cue 页。两端只在这里定。
    static let first: Route = .cue

    /// 会话页；`seed` 是推入前读好的这一页（iOS 的 `openSession`），通知跳转等只有记录 id 的入口不带。
    static func session(_ id: UUID, sessionID: String? = nil, seed: SessionDigest? = nil) -> Route {
        .session(SessionRoute(id: id, sessionID: sessionID, seed: seed))
    }

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
