import Foundation

/// 小组件、分享扩展打开主 App 的链接：`cuepad://speak`、`cuepad://project/<id>`、`cuepad://card/<id>`、`cuepad://cue`。
nonisolated enum DeepLink: Equatable, Sendable {
    static let scheme = "cuepad"

    /// 打开 Cue 页，"对 Cue 说"拿到焦点（随手记也在那里说）。
    case speak
    case project(UUID)
    case card(UUID)
    /// 打开 Cue 页。
    case cue

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (host, parts.count) {
        case ("speak", 0):
            self = .speak
        case ("cue", 0):
            self = .cue
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
        case .speak: URL(string: "cuepad://speak")!
        case .project(let id): URL(string: "cuepad://project/\(id.uuidString.lowercased())")!
        case .card(let id): URL(string: "cuepad://card/\(id.uuidString.lowercased())")!
        case .cue: URL(string: "cuepad://cue")!
        }
    }
}
