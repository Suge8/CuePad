import CueStore
import Foundation

/// 去哪一页：两端同一个值，都经 `Workspace.show` 去；Mac 内容区挂哪一页与 iOS 导航栈里推入哪一页只差呈现（`Workspace.Layout`）
/// （Mac 只用其中的 `project`、`archive`、`trash`、`progress`、`cue`、`session`）。
nonisolated enum Route: Hashable {
    /// 项目书架：全部项目（iPhone 底部那一排的"项目"）。
    case shelf
    case project(UUID)
    case archive
    case trash
    case settings
    case conflicts
    /// 进展：跨项目的看板与会话两段（`Workspace.progressPane`；侧栏与 iPhone 底部的"进展"）。
    case progress
    /// Cue 页：和总控 Agent Cue 的对话（`CuePage`）。
    case cue
    /// Cue 的设置（手机从 Cue 面板推入，`CueSettingsScreen`；Mac 的在设置窗口里）。
    case cueSettings
    case search
    case card(UUID)
    /// 一个 Pi 会话的整页（近况与回复）。
    case session(SessionRoute)

    /// 打开 App 没有要回去的项目时（第一次打开、上次的项目进了回收站）落在哪：Cue 页。两端只在这里定。
    static let first: Route = .cue

    /// 会话页；`seed` 是去之前读好的这一页（`Workspace.openSession`，iOS 推入的第一帧用它）。
    static func session(_ id: UUID, sessionID: String? = nil, seed: SessionDigest? = nil) -> Route {
        .session(SessionRoute(id: id, sessionID: sessionID, seed: seed))
    }

    /// 从 Pi 的会话 id 去会话页（Mac 的侧栏、搜索）。
    static func session(_ sessionID: String) -> Route { .session(PiSessionState.recordID(sessionID: sessionID), sessionID: sessionID) }

    /// 窄屏（`Workspace.Layout.dock`）上它所属的去处（底部那一排的去处与 Cue 之一）：去处本身是它自己；卡片纸页、会话页、搜索不属于哪一页（推在当前页上），为 nil。
    var home: Route? {
        switch self {
        case .cue, .cueSettings: .cue
        case .progress: .progress
        case .shelf, .project, .archive, .trash, .settings, .conflicts: .shelf
        case .search, .card, .session: nil
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
