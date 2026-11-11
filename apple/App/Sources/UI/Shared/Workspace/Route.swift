import CueStore
import Foundation

nonisolated enum Route: Hashable {
    case shelf
    case project(UUID)
    case archive
    case trash
    case library
    /// iOS 推入；Mac 盖在当前页上。
    case libraryFile(LibraryFile)
    case settings
    case conflicts
    case progress
    case cue
    case search
    case earlier
    case card(UUID)
    case session(SessionRoute)

    static func session(_ id: UUID, sessionID: String? = nil, seed: SessionDigest? = nil) -> Route {
        .session(SessionRoute(id: id, sessionID: sessionID, seed: seed))
    }

    static func session(_ sessionID: String) -> Route { .session(SessionState.recordID(sessionID: sessionID), sessionID: sessionID) }


}

extension Route {
    /// 只有哪种页，不带内容：会话页的 `seed` 是整页的对话。
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

/// `sessionID` 是 Pi 的会话 id（Mac 的桥按它认在线的会话），只有记录 id 的入口不带。`seed` 是推入前读好的这一页，只作首帧，
/// 之后一律以 Store 的观察流为准；两者都不参与相等。
nonisolated struct SessionRoute: Hashable {
    let id: UUID
    var sessionID: String?
    var seed: SessionDigest?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
