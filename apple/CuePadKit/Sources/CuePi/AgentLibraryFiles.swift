#if os(macOS)
import CueStore
import Foundation
import Synchronization

/// 技能与说明的文件（事实源，CuePad 不存副本）：读成快照（`AgentLibrary`，判定规则在 `LibrarySkillScan`、`LibraryInstructionScan`）、
/// 跟着文件变化重读（`keep`）、整理与撤销、写说明。写入只在用户动作时（整理、编辑），后台只读。
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

    /// `projects` 是这台绑了文件夹的项目（`CueStore.projectDirectories`）。
    @concurrent public func scan(host: String, projects: [UUID: String]) async -> AgentLibrary { read(host: host, projects: projects).library }

    private func read(host: String, projects: [UUID: String]) -> (library: AgentLibrary, watched: Set<String>) {
        let places = places(projects)
        let skills = LibrarySkillScan(places), instructions = LibraryInstructionScan(places)
        let library = AgentLibrary(
            hostID: host, home: integration.paths.userHome.path, skills: skills.skills, instructions: instructions.instructions,
            tidies: Self.ordered(skills.tidies + instructions.tidies), selfManaged: skills.selfManaged, modifiedAt: Date())
        // 各家的目录也盯着：装上一家（建出它的目录）就多一家要链接、要比的说明
        let homes = AgentKind.allCases.filter(integration.touches).map { integration.paths.home(of: $0).path }
        return (library, skills.watched.union(instructions.watched).union(homes + [integration.paths.agentsDirectory.path]))
    }

    /// 要整理的按 `LibraryTidy.Kind` 的先后。
    private static func ordered(_ tidies: [LibraryTidy]) -> [LibraryTidy] {
        func rank(_ kind: LibraryTidy.Kind) -> Int {
            switch kind {
            case .stray: 0
            case .unlinked: 1
            case .duplicate: 2
            case .malformed: 3
            case .empty: 4
            case .globalInstructions: 5
            case .projectClaude: 6
            }
        }
        return tidies.enumerated().sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }.map(\.element)
    }

    /// 照此刻的文件做这几件（那件已不在的不做，一件都不在抛 `tidyGone`）：返回做了几件与撤销。中途出错先把做了的放回再抛。
    @concurrent public func tidy(_ orders: [TidyOrder], projects: [UUID: String]) async throws -> (count: Int, undo: LibraryUndo) {
        let places = places(projects)
        let current = read(host: "", projects: projects).library.tidies
        guard orders.contains(where: { order in current.contains { $0.id == order.tidy } }) else { throw AgentLibraryError.tidyGone }
        var tidying = LibraryTidying(places: places, trash: trash)
        var count = 0
        do {
            for order in orders {
                guard let tidy = current.first(where: { $0.id == order.tidy }) else { continue }
                if try tidying.run(tidy, order) { count += 1 }
            }
        } catch {
            try? LibraryTidying.revert(tidying.undo)
            throw error
        }
        return (count, tidying.undo)
    }

    @concurrent public func undo(_ undo: LibraryUndo) async throws { try LibraryTidying.revert(undo) }

    /// 写一份说明：文件此刻的内容不是 `edit.base` 就不写，抛 `changedOnMac`。链接写进它指的文件；还没有的建出来。
    @concurrent public func write(_ edit: InstructionEdit, projects: [UUID: String]) async throws {
        let file = try places(projects).file(edit.instruction).realPath
        guard LibraryInstruction.base(of: LibraryInstructionScan.read(file)) == edit.base else { throw AgentLibraryError.changedOnMac }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(edit.text.utf8).write(to: file, options: .atomic)
    }

    /// 跟着文件与绑定的文件夹（`projects`，每次变了给一次全部）重读，每读一次交给 `record`（内容没变不写由它管）。
    /// 盯读到的每个目录与文件（`FileFollower`，当场）；读的时候又变了的并成下一次。直到所在任务取消或 `projects` 结束。
    public func keep(
        host: String, projects: some AsyncSequence<[UUID: String], any Error> & Sendable, record: @escaping @Sendable (AgentLibrary) async throws -> Void
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
                    let (library, watched) = read(host: host, projects: projects)
                    try await record(library)
                    follower.follow(only: Set(watched.map { URL(filePath: $0).realPath.path }))
                }
                follower.stop()
            }
        }
    }
}
#endif
