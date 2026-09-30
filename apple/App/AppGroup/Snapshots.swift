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

/// 收件箱快照：主 App 写，小组件读。
nonisolated struct InboxSnapshot: Codable, Equatable, Sendable {
    struct Card: Codable, Equatable, Sendable {
        var id: UUID
        /// 第一行文字；没有文字（只有图片）为空。
        var title: String
        var modifiedAt: Date
    }

    /// 最近修改的几张，新的在前。
    var cards: [Card]
    /// 收件箱里的卡片总数。
    var total: Int
}

/// 快照文件的读写：每种快照一个 JSON，原子替换，读的一方随时都能读到完整内容。
nonisolated enum Snapshots {
    static func write(_ snapshot: ProjectsSnapshot, to directory: URL) throws {
        try write(snapshot, named: "projects.json", to: directory)
    }

    static func write(_ snapshot: InboxSnapshot, to directory: URL) throws {
        try write(snapshot, named: "inbox.json", to: directory)
    }

    static func readProjects(from directory: URL) -> ProjectsSnapshot? {
        read(named: "projects.json", from: directory)
    }

    static func readInbox(from directory: URL) -> InboxSnapshot? {
        read(named: "inbox.json", from: directory)
    }

    private static func write<T: Encodable>(_ value: T, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: directory.appending(path: name), options: .atomic)
    }

    private static func read<T: Decodable>(named name: String, from directory: URL) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(T.self, from: data)
    }
}
