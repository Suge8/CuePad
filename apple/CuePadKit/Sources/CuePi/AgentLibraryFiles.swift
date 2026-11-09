#if os(macOS)
import CueStore
import Foundation
import Synchronization

/// 写入只在用户动作时（整理、文件页），后台只读。
public struct AgentLibraryFiles: Sendable {
    private let access: AgentFileAccess
    private let trash: @Sendable (URL) throws -> URL
    /// 读一遍是逐个目录读、不是快照，整理一次也要动好几个目录（搬技能跨两处）：读夹在一次整理或撤销中间，
    /// 会记下两处都没有（少一个技能）或两处都有（多一件同名去重）的一份，同步出去。读与整理、撤销因此互斥（改文件只换一个文件，不用）；别家同时改目录的照旧，靠下一次读补正。
    private let serial = NSLock()

    public init(access: AgentFileAccess, trash: (@Sendable (URL) throws -> URL)? = nil) {
        self.access = access
        self.trash = trash ?? { item in
            var placed: NSURL?
            try FileManager.default.trashItem(at: item, resultingItemURL: &placed)
            return (placed as URL?) ?? item
        }
    }

    /// 隔离运行与测试用。
    public static func trash(into directory: URL) -> @Sendable (URL) throws -> URL {
        { item in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var placed = directory.appending(path: item.lastPathComponent)
            var index = 1
            while FileManager.default.fileExists(atPath: placed.path) || RelativeLink.isLink(placed) {
                index += 1
                placed = directory.appending(path: "\(item.lastPathComponent) \(index)")
            }
            try FileManager.default.moveItem(at: item, to: placed)
            return placed
        }
    }

    public var isAvailable: Bool { access.touchesShared }

    private func places(_ projects: [UUID: String]) -> AgentLibraryPlaces {
        AgentLibraryPlaces(paths: access.paths, touches: access.touches, projects: projects)
    }

    public struct Scan: Sendable {
        public let library: AgentLibrary
        public let texts: [String: String]
    }

    private func read(host: String, projects: [UUID: String]) -> (scan: Scan, watched: Set<String>) {
        let places = places(projects)
        let skills = LibrarySkillScan(places), instructions = LibraryInstructionScan(places)
        let library = AgentLibrary(
            hostID: host, home: access.paths.userHome.path, skills: skills.skills, instructions: instructions.instructions,
            tidies: Self.ordered(skills.tidies + instructions.tidies), selfManaged: skills.selfManaged, agents: places.installed,
            modifiedAt: Date())
        // 各家的目录也盯着：装上一家（建出它的目录）就多一家要链接、要比的规则
        let homes = AgentKind.allCases.filter(access.touches).map { access.paths.home(of: $0).path }
        let texts = skills.texts.merging(instructions.texts) { a, _ in a }
        return (Scan(library: library, texts: texts), skills.watched.union(instructions.watched).union(homes + [access.paths.agentsDirectory.path]))
    }

    private static func ordered(_ tidies: [LibraryTidy]) -> [LibraryTidy] {
        func rank(_ kind: LibraryTidy.Kind) -> Int {
            switch kind {
            case .stray: 0
            case .unlinked: 1
            case .duplicate: 2
            case .empty: 3
            case .globalInstructions: 4
            case .projectClaude: 5
            }
        }
        return tidies.enumerated().sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }.map(\.element)
    }

    /// 那件已不在的不做，一件都不在抛 `tidyGone`；中途出错先把做了的放回再抛。
    @concurrent public func tidy(_ orders: [TidyOrder], projects: [UUID: String]) async throws -> (count: Int, undo: LibraryUndo) {
        try serial.withLock {
            let places = places(projects)
            let scan = read(host: "", projects: projects).scan, current = scan.library.tidies
            guard orders.contains(where: { order in current.contains { $0.id == order.tidy } }) else { throw AgentLibraryError.tidyGone }
            var tidying = LibraryTidying(places: places, texts: scan.texts, trash: trash)
            var count = 0
            do {
                for order in orders {
                    guard let tidy = current.first(where: { $0.id == order.tidy }) else { continue }
                    if let base = order.base, tidy.base != base { throw AgentLibraryError.changedOnMac }
                    try tidying.run(tidy, order)
                    count += 1
                }
            } catch {
                try? LibraryTidying.revert(tidying.undo)
                throw error
            }
            return (count, tidying.undo)
        }
    }

    @concurrent public func undo(_ undo: LibraryUndo) async throws { try serial.withLock { try LibraryTidying.revert(undo) } }

    /// 文件此刻的内容（同快照里的读法）不是 `edit.base` 就不写，抛 `changedOnMac`。链接写进它指的文件；
    /// 还没有的规则建出来，已经不在的技能抛 `gone`。
    @concurrent public func write(_ edit: LibraryEdit, projects: [UUID: String]) async throws {
        let file: URL, current: String?
        switch edit.file {
        case .instruction(let kind):
            file = try places(projects).file(kind).realPath
            current = LibraryFileReading.content(file)
        case .skill(let path):
            file = URL(filePath: path, directoryHint: .isDirectory).appending(path: AgentSkill.fileName).realPath
            guard FileManager.default.fileExists(atPath: file.path) else { throw AgentLibraryError.gone }
            current = LibraryFileReading.read(file) ?? ""
        }
        guard LibraryEdit.base(of: current) == edit.base else { throw AgentLibraryError.changedOnMac }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(edit.text.utf8).write(to: file, options: .atomic)
    }

    /// `projects` 每次变了给一次全部；每读一次交给 `record`（内容没变不写由它管）；读的时候又变了的并成下一次，直到所在任务取消或 `projects` 结束。
    public func keep(
        host: String, projects: some AsyncSequence<[UUID: String], any Error> & Sendable, record: @escaping @Sendable (Scan) async throws -> Void
    ) async throws {
        let follower = FileFollower()
        defer { follower.stop() }
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let latest = Mutex<[UUID: String]?>(nil)
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                for try await next in projects {
                    latest.withLock { $0 = next }
                    changed.yield()
                }
                changed.finish()
            }
            group.addTask {
                for await _ in follower.paths { changed.yield() }
            }
            group.addTask {
                for await _ in changes {
                    guard let projects = latest.withLock({ $0 }) else { continue }
                    let (scan, watched) = serial.withLock { read(host: host, projects: projects) }
                    try await record(scan)
                    follower.follow(only: Set(watched.map { URL(filePath: $0).realPath.path }))
                }
                follower.stop()
            }
        }
    }
}
#endif
