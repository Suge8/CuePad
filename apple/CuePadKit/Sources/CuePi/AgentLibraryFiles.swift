#if os(macOS)
import CueStore
import Foundation
import Synchronization

/// 技能与规则的文件（事实源）：读成快照（`AgentLibrary`，判定规则在 `LibrarySkillScan`、`LibraryInstructionScan`）与各份文件的正文、
/// 跟着文件变化重读（`keep`）、整理与撤销、改一份文件。写入只在用户动作时（整理、文件页），后台只读。
/// 碰得了哪些目录同接入（`AgentIntegration.touches`）：隔离运行而几家共读的 `~/.agents` 是真实位置时什么都不读（`isAvailable`）。
public struct AgentLibraryFiles: Sendable {
    private let integration: AgentIntegration
    /// 移走的放到哪、返回放下的位置：缺省是系统废纸篓，隔离运行与测试给库里的一个目录
    private let trash: @Sendable (URL) throws -> URL

    public init(integration: AgentIntegration, trash: (@Sendable (URL) throws -> URL)? = nil) {
        self.integration = integration
        self.trash = trash ?? { item in
            var placed: NSURL?
            try FileManager.default.trashItem(at: item, resultingItemURL: &placed)
            return (placed as URL?) ?? item
        }
    }

    /// 放进 `directory` 的废纸篓（隔离运行与测试用）：同名的加序号。
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

    public var isAvailable: Bool { integration.touchesShared }

    private func places(_ projects: [UUID: String]) -> AgentLibraryPlaces {
        AgentLibraryPlaces(paths: integration.paths, touches: integration.touches, projects: projects)
    }

    /// 读一次：快照与它列出的各份文件的正文（路径 → 正文，`LibraryFileText`）。`projects` 是这台绑了文件夹的项目（`CueStore.projectDirectories`）。
    public struct Scan: Sendable {
        public let library: AgentLibrary
        public let texts: [String: String]
    }

    @concurrent public func scan(host: String, projects: [UUID: String]) async -> Scan { read(host: host, projects: projects).scan }

    private func read(host: String, projects: [UUID: String]) -> (scan: Scan, watched: Set<String>) {
        let places = places(projects)
        let skills = LibrarySkillScan(places), instructions = LibraryInstructionScan(places)
        let library = AgentLibrary(
            hostID: host, home: integration.paths.userHome.path, skills: skills.skills, instructions: instructions.instructions,
            tidies: Self.ordered(skills.tidies + instructions.tidies), selfManaged: skills.selfManaged, agents: places.installed,
            modifiedAt: Date())
        // 各家的目录也盯着：装上一家（建出它的目录）就多一家要链接、要比的规则
        let homes = AgentKind.allCases.filter(integration.touches).map { integration.paths.home(of: $0).path }
        let texts = skills.texts.merging(instructions.texts) { a, _ in a }
        return (Scan(library: library, texts: texts), skills.watched.union(instructions.watched).union(homes + [integration.paths.agentsDirectory.path]))
    }

    /// 该整理的按 `LibraryTidy.Kind` 的先后。
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

    /// 照此刻的文件做这几件（那件已不在的不做，一件都不在抛 `tidyGone`）：返回做了几件与撤销。中途出错先把做了的放回再抛。
    @concurrent public func tidy(_ orders: [TidyOrder], projects: [UUID: String]) async throws -> (count: Int, undo: LibraryUndo) {
        let places = places(projects)
        let scan = read(host: "", projects: projects).scan, current = scan.library.tidies
        guard orders.contains(where: { order in current.contains { $0.id == order.tidy } }) else { throw AgentLibraryError.tidyGone }
        var tidying = LibraryTidying(places: places, texts: scan.texts, trash: trash)
        var count = 0
        do {
            for order in orders {
                guard let tidy = current.first(where: { $0.id == order.tidy }) else { continue }
                try tidying.run(tidy, order)
                count += 1
            }
        } catch {
            try? LibraryTidying.revert(tidying.undo)
            throw error
        }
        return (count, tidying.undo)
    }

    @concurrent public func undo(_ undo: LibraryUndo) async throws { try LibraryTidying.revert(undo) }

    /// 改一份文件：文件此刻的内容（同快照里的读法）不是 `edit.base` 就不写，抛 `changedOnMac`。链接写进它指的文件；
    /// 还没有的规则建出来，已经不在的技能抛 `gone`。
    @concurrent public func write(_ edit: LibraryEdit, projects: [UUID: String]) async throws {
        let file: URL, current: String?
        switch edit.file {
        case .instruction(let kind):
            file = try places(projects).file(kind).realPath
            current = LibraryInstructionScan.content(file)
        case .skill(let path):
            file = URL(filePath: path, directoryHint: .isDirectory).appending(path: AgentSkill.fileName).realPath
            guard FileManager.default.fileExists(atPath: file.path) else { throw AgentLibraryError.gone }
            current = LibraryInstructionScan.read(file) ?? ""
        }
        guard LibraryEdit.base(of: current) == edit.base else { throw AgentLibraryError.changedOnMac }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(edit.text.utf8).write(to: file, options: .atomic)
    }

    /// 跟着文件与绑定的文件夹（`projects`，每次变了给一次全部）重读，每读一次交给 `record`（内容没变不写由它管）。
    /// 盯读到的每个目录与文件（`FileFollower`，当场）；读的时候又变了的并成下一次。直到所在任务取消或 `projects` 结束。
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
                    let (scan, watched) = read(host: host, projects: projects)
                    try await record(scan)
                    follower.follow(only: Set(watched.map { URL(filePath: $0).realPath.path }))
                }
                follower.stop()
            }
        }
    }
}
#endif
