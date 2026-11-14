#if os(macOS)
import CueStore
import Foundation
import os
import Synchronization

/// 这台 Mac 的技能与规则（同步表 agentLibraries 与各份正文 agentLibraryFiles）只经这里写；整理与改文件也经这里，做完的文件变化照样经重读写进库。
/// 写文件只在用户动作时（整理、文件页），后台只读。
public struct AgentLibraryFiles: Sendable {
    private static let log = Logger(subsystem: AppIdentity.id, category: "library")
    private let store: CueStore
    private let host: String
    private let access: AgentFileAccess
    private let trash: @Sendable (URL) throws -> URL
    /// 读一遍是逐个目录读、不是快照，整理一次也要动好几个目录（搬技能跨两处）：读夹在一次整理或撤销中间，
    /// 会记下两处都没有（少一个技能）或两处都有（多一件同名去重）的一份，同步出去。读与整理、撤销因此互斥（改文件只换一个文件，不用）；别家同时改目录的照旧，靠下一次读补正。
    private let serial = NSLock()

    public init(store: CueStore, host: String, access: AgentFileAccess, trash: (@Sendable (URL) throws -> URL)? = nil) {
        self.store = store
        self.host = host
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

    private var isAvailable: Bool { access.touchesShared }

    private func places(_ projects: [UUID: String]) -> AgentLibraryPlaces {
        AgentLibraryPlaces(paths: access.paths, touches: access.touches, grokClaude: access.grokClaude, projects: projects)
    }

    private struct Scan: Sendable {
        let library: AgentLibrary
        let texts: [String: String]
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
    @concurrent public func tidy(_ orders: [TidyOrder]) async throws -> (count: Int, undo: LibraryUndo) {
        let projects = try await store.projectDirectories()
        return try serial.withLock {
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
                // 报给用户的仍是让整理停下的那个错；放回也失败时文件停在半途，只能从日志查哪些没放回
                do { try LibraryTidying.revert(tidying.undo) } catch let revert {
                    Self.log.error("整理中途出错后放回失败，文件停在半途：\(String(describing: revert), privacy: .public)")
                }
                throw error
            }
            return (count, tidying.undo)
        }
    }

    @concurrent public func undo(_ undo: LibraryUndo) async throws { try serial.withLock { try LibraryTidying.revert(undo) } }

    /// 文件此刻的内容（同快照里的读法）不是 `edit.base` 就不写，抛 `changedOnMac`。链接写进它指的文件；
    /// 还没有的规则建出来，已经不在的技能抛 `gone`。
    @concurrent public func write(_ edit: LibraryEdit) async throws {
        let projects = try await store.projectDirectories()
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

    /// 跟着项目文件夹与各家目录的变化重读、写进库（内容没变不写由库管），读的时候又变了的并成下一次，直到所在任务取消。
    /// 碰不得几家共读的目录（隔离运行而它是真实位置）时什么都不读、不写。
    public func keep() async throws {
        guard isAvailable else { return }
        let projects = store.observe { try $0.projectDirectories() }
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
                    try await store.recordAgentLibrary(scan.library, texts: scan.texts)
                    follower.follow(only: Set(watched.map { URL(filePath: $0).realPath.path }))
                }
                follower.stop()
            }
        }
    }
}
#endif
