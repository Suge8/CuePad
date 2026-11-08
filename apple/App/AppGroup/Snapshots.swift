import CueStore
import Foundation

/// 项目列表快照：主 App 写，分享扩展（选项目）读。扩展不打开资料库。
nonisolated struct ProjectsSnapshot: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var color: String
        var icon: String?

        var shownName: String { Project.shownName(id: id, name: name) }
    }

    var projects: [Entry]
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
    var shownName: String { Project.shownName(id: Project.defaultID, name: name) }
    var cards: [Card]
    var total: Int
}

/// 主 App 写、小组件与分享扩展读的一种快照：每种一个 JSON 文件。
/// v2 存项目原名，由读取端翻译；旧快照存过译名，无法区分用户改名，换文件名使旧缓存失效。
nonisolated protocol SnapshotFile: Codable, Sendable {
    static var fileName: String { get }
}

nonisolated extension ProjectsSnapshot: SnapshotFile { static let fileName = "projects-v2.json" }
nonisolated extension DefaultProjectSnapshot: SnapshotFile { static let fileName = "default-project-v2.json" }

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
