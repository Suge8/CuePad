#if os(macOS)
import CueStore
import Foundation

/// 一次整理改了什么（按先后），撤销时倒着放回：搬走的搬回、进了废纸篓的放回原处、建的链接与目录删掉、改写的文件写回原样。
public struct LibraryUndo: Sendable {
    enum Step: Sendable {
        case moved(from: URL, to: URL)
        case trashed(URL, into: URL)
        case linked(URL)
        case createdDirectory(URL)
        /// 改写之前的内容；之前没有这个文件为 nil
        case wrote(URL, previous: Data?)
    }

    var steps: [Step] = []
}

/// 照一次扫出来的要整理的做（`AgentLibraryFiles.tidy`），每一步记进 `undo`。
struct LibraryTidying {
    let places: AgentLibraryPlaces
    let trash: @Sendable (URL) throws -> URL
    private(set) var undo = LibraryUndo()

    init(places: AgentLibraryPlaces, trash: @escaping @Sendable (URL) throws -> URL) {
        self.places = places
        self.trash = trash
    }

    /// 做一件；格式不对的那件没有可做的（打开它自己改），返回 false。
    mutating func run(_ tidy: LibraryTidy, _ order: TidyOrder) throws -> Bool {
        switch tidy.kind {
        case .stray(let moves):
            for move in moves { try moveSkill(move) }
        case .unlinked(let skills):
            for skill in skills { try linkForClaude(skill.name, URL(filePath: skill.path), in: skill.scope) }
        case .duplicate(_, let copies):
            guard let keep = order.keep, copies.contains(where: { $0.skill.path == keep }) else { throw AgentLibraryError.tidyGone }
            for copy in copies where copy.skill.path != keep { try moveToTrash(URL(filePath: copy.skill.path)) }
        case .malformed:
            return false
        case .empty(let directories):
            for directory in directories { try moveToTrash(URL(filePath: directory)) }
        case .globalInstructions:
            try mergeGlobal(tidy, retiring: order.retire)
        case .projectClaude(let project, _):
            guard let file = places.projectInstructions(project), let claude = places.projectClaude(project) else { throw AgentLibraryError.noFolder }
            try write(tidy.merged() ?? "", to: file)
            try moveToTrash(claude)
        }
        return true
    }

    /// 搬进同层的 `.agents/skills`；Claude Code 用着时在它读的位置链回来（搬走的若就在那里，链接正好补上空出的位置）。
    private mutating func moveSkill(_ move: SkillMove) throws {
        let from = URL(filePath: move.skill.path), to = URL(filePath: move.to)
        guard !FileManager.default.fileExists(atPath: to.path) else { return }
        try ensureDirectory(to.deletingLastPathComponent())
        try FileManager.default.moveItem(at: from, to: to)
        undo.steps.append(.moved(from: from, to: to))
        try linkForClaude(move.skill.name, to, in: move.skill.scope)
    }

    private mutating func linkForClaude(_ name: String, _ skill: URL, in scope: LibraryScope) throws {
        guard let link = places.claudeSkills(scope)?.appending(path: name, directoryHint: .isDirectory),
              !FileManager.default.fileExists(atPath: link.path), !RelativeLink.isLink(link) else { return }
        try ensureDirectory(link.deletingLastPathComponent())
        try RelativeLink.make(at: link, to: skill)
        undo.steps.append(.linked(link))
    }

    /// 合成一份全局说明，各家换成链到它的链接；OpenCode 自己那份移走（没有它时读 Claude Code 的）；撤掉选中的替换基础提示。
    private mutating func mergeGlobal(_ tidy: LibraryTidy, retiring: Set<InstructionSource.Origin>) throws {
        let shared = places.globalInstructions
        try write(tidy.merged(retiring: retiring) ?? "", to: shared)
        for kind in places.linkedKinds {
            let file = places.globalFile(kind)
            guard !RelativeLink.points(file, to: shared) else { continue }
            if RelativeLink.isLink(file) { continue }  // 指到别处的不碰
            if FileManager.default.fileExists(atPath: file.path) { try moveToTrash(file) }
            try RelativeLink.make(at: file, to: shared)
            undo.steps.append(.linked(file))
        }
        let openCode = places.globalFile(.opencode)
        if places.uses(.opencode), !RelativeLink.isLink(openCode), FileManager.default.fileExists(atPath: openCode.path) { try moveToTrash(openCode) }
        if retiring.contains(.piSystem), FileManager.default.fileExists(atPath: places.piSystem.path) { try moveToTrash(places.piSystem) }
        if retiring.contains(.codexPrompt), let key = CodexPromptKey(places) { try write(key.removed, to: key.config) }
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
        undo.steps.append(.wrote(target, previous: previous))
    }

    /// 建出还没有的目录，记下最上面新建的那一层。
    private mutating func ensureDirectory(_ directory: URL) throws {
        var top = directory
        while !FileManager.default.fileExists(atPath: top.deletingLastPathComponent().path), top.pathComponents.count > 1 { top = top.deletingLastPathComponent() }
        guard !FileManager.default.fileExists(atPath: top.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        undo.steps.append(.createdDirectory(top))
    }

    /// 倒着放回。放回的位置已被占（撤销前又有了同名的）就停下报错，已放回的不再动。
    static func revert(_ undo: LibraryUndo) throws {
        let files = FileManager.default
        for step in undo.steps.reversed() {
            switch step {
            case .moved(let from, let to):
                try files.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: to, to: from)
            case .trashed(let original, let trashed):
                try files.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: trashed, to: original)
            case .linked(let link):
                if RelativeLink.isLink(link) { try files.removeItem(at: link) }
            case .createdDirectory(let directory):
                if (try? files.contentsOfDirectory(atPath: directory.path))?.allSatisfy({ $0 == ".DS_Store" }) == true { try files.removeItem(at: directory) }
            case .wrote(let file, let previous):
                if let previous { try previous.write(to: file, options: .atomic) } else { try files.removeItem(at: file) }
            }
        }
    }
}
#endif
