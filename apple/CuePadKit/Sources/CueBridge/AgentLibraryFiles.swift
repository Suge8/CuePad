#if os(macOS)
import CueStore
import Foundation
import os
import Synchronization

public struct AgentLibraryFiles: Sendable {
    private static let log = Logger(subsystem: AppIdentity.id, category: "library")
    private let store: CueStore
    private let host: String
    private let access: AgentFileAccess
    private let trash: @Sendable (URL) throws -> URL
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
                do { try LibraryTidying.revert(tidying.undo) } catch let revert {
                    Self.log.error("整理中途出错后放回失败，文件停在半途：\(String(describing: revert), privacy: .public)")
                }
                throw error
            }
            return (count, tidying.undo)
        }
    }

    @concurrent public func undo(_ undo: LibraryUndo) async throws { try serial.withLock { try LibraryTidying.revert(undo) } }

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
