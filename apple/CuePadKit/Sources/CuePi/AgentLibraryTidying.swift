#if os(macOS)
import CueStore
import Foundation

/// 一次整理改了什么（按先后），撤销时倒着放回：搬走的搬回、进了废纸篓的放回原处、建的链接与目录删掉、改写的文件写回原样。
/// 整理之后又有人动过这些文件（改了合并的规则、换了链接、在放回的位置上又建了东西），撤销就整个不做（`changedSinceTidy`），不盖掉后来的改动。
public struct LibraryUndo: Sendable {
    enum Step: Sendable {
        case moved(from: URL, to: URL)
        case trashed(URL, into: URL)
        case linked(URL, to: URL)
        case createdDirectory(URL)
        /// 改写之前的内容（之前没有这个文件为 nil）与写下的内容
        case wrote(URL, previous: Data?, written: Data)
    }

    var steps: [Step] = []
}

/// 照一次扫出来的该整理的做（`AgentLibraryFiles.tidy`），每一步记进 `undo`。
struct LibraryTidying {
    let places: AgentLibraryPlaces
    let trash: @Sendable (URL) throws -> URL
    private(set) var undo = LibraryUndo()

    init(places: AgentLibraryPlaces, trash: @escaping @Sendable (URL) throws -> URL) {
        self.places = places
        self.trash = trash
    }

    /// 做一件。
    mutating func run(_ tidy: LibraryTidy, _ order: TidyOrder) throws {
        switch tidy.kind {
        case .stray(let moves):
            for move in moves { try moveSkill(move) }
        case .unlinked(let agent, let skills):
            for skill in skills { if let link = places.link(skill.name, for: agent, in: skill.scope) { try make(link, to: URL(filePath: skill.path)) } }
        case .duplicate(_, let copies):
            guard let keep = order.keep else { throw AgentLibraryError.tidyGone }
            guard let kept = copies.first(where: { $0.path == keep })?.scope else { throw AgentLibraryError.tidyGone }
            // 只移走和留下的那份撞名的：同一层的、全局的（留的是项目里的），留的是全局的就是各项目里的全部
            for copy in copies where copy.path != keep && (copy.scope == kept || copy.scope == .global || kept == .global) {
                try moveToTrash(URL(filePath: copy.path))
            }
        case .empty(let directories):
            for directory in directories { try moveToTrash(URL(filePath: directory)) }
        case .globalInstructions:
            try mergeGlobal(tidy, retiring: order.retire)
        case .projectClaude(let project, _):
            guard let file = places.projectInstructions(project), let claude = places.projectClaude(project) else { throw AgentLibraryError.noFolder }
            try mergeProject(tidy, into: file, claude: claude)
        }
    }

    /// 搬进同层的 `.agents/skills`；读不到那里的几家在它们读的位置链回来（搬走的若就在那里，链接正好补上空出的位置）。
    private mutating func moveSkill(_ move: SkillMove) throws {
        let from = URL(filePath: move.skill.path), to = URL(filePath: move.to)
        guard !FileManager.default.fileExists(atPath: to.path) else { return }
        try ensureDirectory(to.deletingLastPathComponent())
        try FileManager.default.moveItem(at: from, to: to)
        undo.steps.append(.moved(from: from, to: to))
        let root = places.skills(move.skill.scope)?.path ?? ""
        let group = to.deletingLastPathComponent().path.dropFirst(root.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for (_, link) in places.links(move.skill.name, group: group, in: move.skill.scope) { try make(link, to: to) }
    }

    /// 那里已有东西的不碰。
    private mutating func make(_ link: URL, to skill: URL) throws {
        guard !FileManager.default.fileExists(atPath: link.path), !RelativeLink.isLink(link) else { return }
        try ensureDirectory(link.deletingLastPathComponent())
        try RelativeLink.make(at: link, to: skill)
        undo.steps.append(.linked(link, to: skill))
    }

    /// 合并成一份全局规则，各家换成链到它的链接；OpenCode 自己那份移走（没有它时读 Claude Code 的）；撤掉选中的替换基础提示。
    private mutating func mergeGlobal(_ tidy: LibraryTidy, retiring: Set<InstructionSource.Origin>) throws {
        let shared = places.globalInstructions
        try write(tidy.merged(retiring: retiring) ?? "", to: shared)
        for kind in places.linkedKinds {
            let file = places.globalFile(kind)
            guard !RelativeLink.points(file, to: shared) else { continue }
            if RelativeLink.isLink(file) { continue }  // 指到别处的不碰
            if FileManager.default.fileExists(atPath: file.path) { try moveToTrash(file) }
            try RelativeLink.make(at: file, to: shared)
            undo.steps.append(.linked(file, to: shared))
        }
        let openCode = places.globalFile(.opencode)
        if places.uses(.opencode), !RelativeLink.isLink(openCode), FileManager.default.fileExists(atPath: openCode.path) { try moveToTrash(openCode) }
        if retiring.contains(.piSystem), FileManager.default.fileExists(atPath: places.piSystem.path) { try moveToTrash(places.piSystem) }
        if retiring.contains(.codexPrompt), let key = CodexPromptKey(places) { try write(key.removed, to: key.config) }
    }

    /// 合进项目的 AGENTS.md，Claude Code 读的两份移走、`CLAUDE.md` 换成链到 AGENTS.md 的链接（同全局）；个人的 `CLAUDE.local.md` 不碰。
    private mutating func mergeProject(_ tidy: LibraryTidy, into file: URL, claude: (main: URL, nested: URL, local: URL)) throws {
        try write(tidy.merged() ?? "", to: file)
        for other in [claude.main, claude.nested] where LibraryInstructionScan.exists(other) && !RelativeLink.points(other, to: file) { try moveToTrash(other) }
        guard !RelativeLink.points(claude.main, to: file) else { return }
        try RelativeLink.make(at: claude.main, to: file)
        undo.steps.append(.linked(claude.main, to: file))
    }

    private mutating func moveToTrash(_ item: URL) throws {
        undo.steps.append(.trashed(item, into: try trash(item)))
    }

    /// 写进文件（链接写进它指的文件）；内容没变不写。
    private mutating func write(_ text: String, to file: URL) throws {
        let target = file.realPath
        let previous = try? Data(contentsOf: target)
        guard previous != Data(text.utf8) else { return }
        try ensureDirectory(target.deletingLastPathComponent())
        try Data(text.utf8).write(to: target, options: .atomic)
        undo.steps.append(.wrote(target, previous: previous, written: Data(text.utf8)))
    }

    /// 建出还没有的目录，记下最上面新建的那一层。
    private mutating func ensureDirectory(_ directory: URL) throws {
        var top = directory
        while !FileManager.default.fileExists(atPath: top.deletingLastPathComponent().path), top.pathComponents.count > 1 { top = top.deletingLastPathComponent() }
        guard !FileManager.default.fileExists(atPath: top.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        undo.steps.append(.createdDirectory(top))
    }

    /// 倒着放回：先按倒放的顺序核对每一步此刻还是整理完的样子，有一步不是就整个不做、抛 `changedSinceTidy`。
    static func revert(_ undo: LibraryUndo) throws {
        guard isIntact(undo) else { throw AgentLibraryError.changedSinceTidy }
        let files = FileManager.default
        for step in undo.steps.reversed() {
            switch step {
            case .moved(let from, let to):
                try files.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: to, to: from)
            case .trashed(let original, let trashed):
                try files.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: trashed, to: original)
            case .linked(let link, _):
                try files.removeItem(at: link)
            case .createdDirectory(let directory):
                if (try? files.contentsOfDirectory(atPath: directory.path))?.allSatisfy({ $0 == ".DS_Store" }) == true { try files.removeItem(at: directory) }
            case .wrote(let file, let previous, _):
                if let previous { try previous.write(to: file, options: .atomic) } else { try files.removeItem(at: file) }
            }
        }
    }

    /// 每一步此刻都还是整理完的样子：搬去、放进废纸篓的还在，原处空着（或是倒放时先删掉的链接、文件），建的链接还指着原处，写的文件没再改过。
    private static func isIntact(_ undo: LibraryUndo) -> Bool {
        let files = FileManager.default
        func present(_ url: URL) -> Bool { files.fileExists(atPath: url.path) || RelativeLink.isLink(url) }
        var freed: Set<String> = []
        func vacant(_ url: URL) -> Bool { !present(url) || freed.contains(url.path) }
        for step in undo.steps.reversed() {
            switch step {
            case .moved(let from, let to):
                guard present(to), vacant(from) else { return false }
                freed.insert(to.path)
            case .trashed(let original, let trashed):
                guard present(trashed), vacant(original) else { return false }
            case .linked(let link, let target):
                guard RelativeLink.points(link, to: target) else { return false }
                freed.insert(link.path)
            case .createdDirectory:
                continue
            case .wrote(let file, let previous, let written):
                guard (try? Data(contentsOf: file)) == written else { return false }
                if previous == nil { freed.insert(file.path) }
            }
        }
        return true
    }
}
#endif
