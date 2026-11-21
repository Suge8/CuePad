import CueStore
import Foundation

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

nonisolated struct DefaultProjectSnapshot: Codable, Equatable, Sendable {
    struct Card: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var modifiedAt: Date
    }

    var name: String
    var shownName: String { Project.shownName(id: Project.defaultID, name: name) }
    var cards: [Card]
    var total: Int
}

nonisolated protocol SnapshotFile: Codable, Sendable {
    static var fileName: String { get }
}

nonisolated extension ProjectsSnapshot: SnapshotFile { static let fileName = "projects-v2.json" }
nonisolated extension DefaultProjectSnapshot: SnapshotFile { static let fileName = "default-project-v2.json" }

nonisolated enum Snapshots {
    static func write<S: SnapshotFile>(_ snapshot: S, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: directory.appending(path: S.fileName), options: .atomic)
    }

    static func read<S: SnapshotFile>(_: S.Type, from directory: URL) -> S? {
        guard let data = try? Data(contentsOf: directory.appending(path: S.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(S.self, from: data)
    }
}
