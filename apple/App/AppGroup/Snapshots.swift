import Foundation

/// 项目列表快照：主 App 写，分享扩展（选项目）读。扩展不打开资料库。
nonisolated struct ProjectsSnapshot: Codable, Equatable, Sendable {
    struct Project: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var color: String
        var icon: String?
    }

    var projects: [Project]
}

/// 默认项目的快照：主 App 写，小组件读（项目名可改，跟着写）。
nonisolated struct DefaultProjectSnapshot: Codable, Equatable, Sendable {
    struct Card: Codable, Equatable, Sendable {
        var id: UUID
        /// 第一行文字；没有文字（只有图片）为空。
        var title: String
        var modifiedAt: Date
    }

    var name: String
    /// 最近修改的几张灵感，新的在前。
    var cards: [Card]
    /// 默认项目里的灵感总数。
    var total: Int
}

/// Cue 的快照：主 App 写，小组件读（头像、"等你 N"、它最近一句）。
nonisolated struct CueSnapshot: Codable, Equatable, Sendable {
    var name: String
    /// "等你 N"（App 里 `CueWaiting` 的同一个数）。
    var waiting: Int
    /// Cue 最近对你说的一句（纯文字）。
    var lastSaid: String?
    /// 头像的表情（`CueMood` 的原始值，图在小组件自己的资源里）。
    var mood: String
}

/// 主 App 写、小组件与分享扩展读的一种快照：每种一个 JSON 文件。
nonisolated protocol SnapshotFile: Codable, Sendable {
    static var fileName: String { get }
}

nonisolated extension ProjectsSnapshot: SnapshotFile { static let fileName = "projects.json" }
nonisolated extension DefaultProjectSnapshot: SnapshotFile { static let fileName = "default-project.json" }
nonisolated extension CueSnapshot: SnapshotFile { static let fileName = "cue.json" }

/// 快照文件的读写：原子替换，读的一方随时都能读到完整内容。
nonisolated enum Snapshots {
    static func write<S: SnapshotFile>(_ snapshot: S, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: directory.appending(path: S.fileName), options: .atomic)
    }

    /// 没写过或读不出来为 nil。
    static func read<S: SnapshotFile>(_: S.Type, from directory: URL) -> S? {
        guard let data = try? Data(contentsOf: directory.appending(path: S.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(S.self, from: data)
    }
}
