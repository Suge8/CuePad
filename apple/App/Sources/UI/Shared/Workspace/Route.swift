import CueStore
import Foundation

nonisolated enum Route: Hashable {
    case shelf
    case project(UUID)
    case archive
    case trash
    case library
    case libraryFile(LibraryFile)
    case settings
    case conflicts
    case progress
    case cue
    case search
    case card(UUID)
    case session(SessionRoute)

    static func session(_ id: UUID, sessionID: String? = nil, seed: SessionDigest? = nil) -> Route {
        .session(SessionRoute(id: id, sessionID: sessionID, seed: seed))
    }

    static func session(_ sessionID: String) -> Route { .session(SessionState.recordID(sessionID: sessionID), sessionID: sessionID) }


}

extension Route {
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
        case .card: "card"
        case .session: "session"
        }
    }
}

nonisolated struct SessionRoute: Hashable {
    let id: UUID
    var sessionID: String?
    var seed: SessionDigest?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
