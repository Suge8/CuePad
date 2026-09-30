import Foundation

/// 小组件、分享扩展打开主 App 的链接：`cuepad://capture[?project=<id>]`、`cuepad://project/<id>`、`cuepad://card/<id>`。
nonisolated enum DeepLink: Equatable, Sendable {
    static let scheme = "cuepad"

    /// 打开随手记；带项目则记入该项目，否则收件箱。
    case capture(project: UUID?)
    case project(UUID)
    case card(UUID)

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.count) {
        case ("capture", 0):
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "project" }?.value
            guard let value else { self = .capture(project: nil); return }
            guard let id = UUID(uuidString: value) else { return nil }
            self = .capture(project: id)
        case ("project", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .project(id)
        case ("card", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .card(id)
        default:
            return nil
        }
    }

    var url: URL {
        switch self {
        case .capture(nil): URL(string: "cuepad://capture")!
        case .capture(let project?): URL(string: "cuepad://capture?project=\(project.uuidString.lowercased())")!
        case .project(let id): URL(string: "cuepad://project/\(id.uuidString.lowercased())")!
        case .card(let id): URL(string: "cuepad://card/\(id.uuidString.lowercased())")!
        }
    }
}
