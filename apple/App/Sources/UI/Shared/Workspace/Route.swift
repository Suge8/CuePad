import CueStore
import Foundation

/// 去哪一页：两端共用，经 Workspace 的布局入口摆到单栈或宽屏主区。
/// （Mac 只用其中的 `shelf`、`earlier`、`project`、`archive`、`trash`、`library`、`progress`、`cue`、`session`；技能与规则的文件页在 Mac 上盖在当前页上，见 `Workspace.overlay`）。
nonisolated enum Route: Hashable {
    /// 项目书架：全部项目（窄屏侧栏与宽屏主区的“项目”）。
    case shelf
    case project(UUID)
    case archive
    case trash
    /// 技能与规则（`AgentLibrary`）：Mac 侧栏底下那颗、iPhone 的 Cue 面板那一行。
    case library
    /// 一份技能或规则的文件页（iOS 推入；Mac 盖在当前页上）。
    case libraryFile(LibraryFile)
    case settings
    case conflicts
    /// 进展：跨项目的看板（窄屏侧栏与宽屏主区的“进展”）。
    case progress
    /// Cue 页：和总控 Agent Cue 的对话（`CuePage`）。
    case cue
    case search
    /// 更早：已结束的会话，按结束时间分段（`EarlierPage`，三端同一页：窄屏从 Cue 页会话条底下"更早"那一格推入，宽屏点会话条上的"更早"在主区打开）。
    case earlier
    case card(UUID)
    case session(SessionRoute)

    /// 会话页；`seed` 是去之前读好的这一页（`Workspace.openSession`，iOS 推入的第一帧用它）。
    static func session(_ id: UUID, sessionID: String? = nil, seed: SessionDigest? = nil) -> Route {
        .session(SessionRoute(id: id, sessionID: sessionID, seed: seed))
    }

    /// 从 Pi 的会话 id 去会话页（Mac 的侧栏、搜索）。
    static func session(_ sessionID: String) -> Route { .session(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID) }


}

extension Route {
    /// 诊断里记的页名（`MainThreadWatch`）：只有哪种页，不带内容（会话页的 `seed` 是整页的对话）。
    var trail: String {
        switch self {
        case .shelf: "shelf"
        case .project: "project"
        case .archive: "archive"
        case .trash: "trash"
        case .library: "library"
        case .libraryFile: "libraryFile"
        case .settings: "settings"
        case .conflicts: "conflicts"
        case .progress: "progress"
        case .cue: "cue"
        case .search: "search"
        case .earlier: "earlier"
        case .card: "card"
        case .session: "session"
        }
    }
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
