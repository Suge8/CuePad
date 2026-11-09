#if os(macOS)
import CueStore
import Foundation

/// 撤销倒着放回；整理之后又有人动过这些文件（改了合并的规则、换了链接、在放回的位置上又建了东西），撤销就整个不做（`changedSinceTidy`），不盖掉后来的改动。
public struct LibraryUndo: Sendable {
    enum Step: Sendable {
        case moved(from: URL, to: URL)
        case trashed(URL, into: URL)
        case linked(URL, to: URL)
        case createdDirectory(URL)
        case wrote(URL, previous: Data?, written: Data)
    }

    var steps: [Step] = []
}

struct LibraryTidying {
    let places: AgentLibraryPlaces
    let texts: [String: String]
    let trash: @Sendable (URL) throws -> URL
    private(set) var undo = LibraryUndo()

    init(places: AgentLibraryPlaces, texts: [String: String], trash: @escaping @Sendable (URL) throws -> URL) {
        self.places = places
        self.texts = texts
        self.trash = trash
    }

    mutating func run(_ tidy: LibraryTidy, _ order: TidyOrder) throws {
        switch tidy.kind {
        case .stray(let moves):
            for move in moves { try moveSkill(move) }
        case .unlinked(let agent, let skills):
            for skill in skills { if let link = places.link(skill.name, for: agent, in: skill.scope) { try make(link, to: URL(filePath: skill.path)) } }
        case .duplicate(_, let copies):
            guard let keep = order.keep, let kept = copies.first(where: { $0.path == keep })?.scope else { throw AgentLibraryError.tidyGone }
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

    /// 搬走的若就在读不到的几家读的位置上，链接正好补上空出的位置。
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

    private mutating func make(_ link: URL, to skill: URL) throws {
        guard !FileManager.default.fileExists(atPath: link.path), !RelativeLink.isLink(link) else { return }
        try ensureDirectory(link.deletingLastPathComponent())
        try RelativeLink.make(at: link, to: skill)
        undo.steps.append(.linked(link, to: skill))
    }

    private mutating func mergeGlobal(_ tidy: LibraryTidy, retiring: Set<InstructionSource.Origin>) throws {
        let shared = places.globalInstructions
        try write(tidy.merged(retiring: retiring, texts: texts) ?? "", to: shared)
        for kind in places.linkedKinds {
            let file = places.globalFile(kind)
            guard !RelativeLink.points(file, to: shared) else { continue }
            if RelativeLink.isLink(file) { continue }
            if FileManager.default.fileExists(atPath: file.path) { try moveToTrash(file) }
            try RelativeLink.make(at: file, to: shared)
            undo.steps.append(.linked(file, to: shared))
        }
        let openCode = places.globalFile(.opencode)
        if places.uses(.opencode), !RelativeLink.isLink(openCode), FileManager.default.fileExists(atPath: openCode.path) { try moveToTrash(openCode) }
        if retiring.contains(.piSystem), FileManager.default.fileExists(atPath: places.piSystem.path) { try moveToTrash(places.piSystem) }
        if retiring.contains(.codexPrompt), let key = CodexPromptKey(places) { try write(key.removed, to: key.config) }
    }

    private mutating func mergeProject(_ tidy: LibraryTidy, into file: URL, claude: (main: URL, nested: URL, local: URL)) throws {
        try write(tidy.merged(texts: texts) ?? "", to: file)
        for other in [claude.main, claude.nested] where LibraryFileReading.exists(other) && !RelativeLink.points(other, to: file) { try moveToTrash(other) }
        guard !RelativeLink.points(claude.main, to: file) else { return }
        try RelativeLink.make(at: claude.main, to: file)
        undo.steps.append(.linked(claude.main, to: file))
    }

    private mutating func moveToTrash(_ item: URL) throws {
        undo.steps.append(.trashed(item, into: try trash(item)))
    }

    private mutating func write(_ text: String, to file: URL) throws {
        let target = file.realPath
        let previous = try? Data(contentsOf: target)
        guard previous != Data(text.utf8) else { return }
        try ensureDirectory(target.deletingLastPathComponent())
        try Data(text.utf8).write(to: target, options: .atomic)
        undo.steps.append(.wrote(target, previous: previous, written: Data(text.utf8)))
    }

    private mutating func ensureDirectory(_ directory: URL) throws {
        var top = directory
        while !FileManager.default.fileExists(atPath: top.deletingLastPathComponent().path), top.pathComponents.count > 1 { top = top.deletingLastPathComponent() }
        guard !FileManager.default.fileExists(atPath: top.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        undo.steps.append(.createdDirectory(top))
    }

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
