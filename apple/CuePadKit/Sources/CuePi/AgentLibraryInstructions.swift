#if os(macOS)
import CueStore
import Foundation

/// 照文件读出规则与规则那两种该整理的（位置见 `AgentLibraryPlaces`）：
/// - 空文件等同没有（`content`）。
/// - 全局：链到 `~/.agents/AGENTS.md` 的几家读它；哪家还有自己的一份（或缺链接），就是"各写一份"——各家自己的那份、
///   共读的那份，连同替换基础提示的两份（Pi 的 SYSTEM.md、Codex 的 `model_instructions_file`）一起比；替换基础提示的两份自己不算问题。
///   指到别处的链接不碰。
/// - 项目：Claude Code 读不到 AGENTS.md 的内容就是问题——`CLAUDE.md` 不是链到它的，而 `CLAUDE.md`、`.claude/CLAUDE.md` 有一份内容不同
///   （空的也算，它照样挡住 AGENTS.md），或有个人的 `CLAUDE.local.md`；内容不同的那几份进合并。
struct LibraryInstructionScan {
    var instructions: [LibraryInstruction] = []
    var tidies: [LibraryTidy] = []
    var watched: Set<String> = []

    init(_ places: AgentLibraryPlaces) {
        scanGlobal(places)
        for scope in places.scopes {
            guard case .project(let id) = scope, let file = places.projectInstructions(id), let claude = places.projectClaude(id) else { continue }
            scanProject(id, file: file, claude: claude, places: places)
        }
    }

    private mutating func scanGlobal(_ places: AgentLibraryPlaces) {
        let shared = places.globalInstructions
        let sharedText = Self.content(shared)
        var sources: [InstructionSource] = sharedText.map { [InstructionSource(origin: .shared, path: shared.path, text: $0, modifiedAt: Self.modified(shared))] } ?? []
        var readers: [AgentKind] = [], links: [String] = [], unlinked = false
        watch(shared)
        for kind in places.linkedKinds {
            let file = places.globalFile(kind)
            watch(file)
            if RelativeLink.points(file, to: shared) {
                if sharedText != nil { readers.append(kind) }
                links.append(file.path)
            } else if RelativeLink.isLink(file) {
                continue
            } else if let text = Self.content(file) {
                sources.append(InstructionSource(origin: .agent(kind), path: file.path, text: text, modifiedAt: Self.modified(file)))
                unlinked = true
            } else {
                unlinked = true
            }
        }
        if places.uses(.opencode) {
            let own = places.globalFile(.opencode)
            watch(own)
            if !RelativeLink.isLink(own), let text = Self.content(own) {
                sources.append(InstructionSource(origin: .agent(.opencode), path: own.path, text: text, modifiedAt: Self.modified(own)))
                unlinked = true
            } else if readers.contains(.claudeCode) {
                readers.append(.opencode)
            }
        }
        let replacements = replacements(places)
        if unlinked, !sources.isEmpty {
            tidies.append(LibraryTidy(id: "global-instructions", kind: .globalInstructions(sources + replacements)))
        }
        instructions.append(LibraryInstruction(
            kind: .global, path: shared.path, text: sharedText, modifiedAt: Self.modified(shared), readers: readers, links: links))
        if places.uses(.pi), let text = Self.content(places.piSystem) {
            instructions.append(LibraryInstruction(kind: .piSystem, path: places.piSystem.path, text: text, modifiedAt: Self.modified(places.piSystem), readers: [.pi]))
        }
    }

    /// 替换基础提示的两份（有才列）；不论要不要比都盯着：SYSTEM.md 留着时是单独一份规则，Codex 的配置里加上这个键就有一份要比。
    private mutating func replacements(_ places: AgentLibraryPlaces) -> [InstructionSource] {
        var found: [InstructionSource] = []
        if places.uses(.pi) {
            watch(places.piSystem)
            if let text = Self.content(places.piSystem) {
                found.append(InstructionSource(origin: .piSystem, path: places.piSystem.path, text: text, modifiedAt: Self.modified(places.piSystem)))
            }
        }
        if places.uses(.codex) {
            watch(places.codexConfig)
            if let prompt = CodexPromptKey(places), let text = Self.content(prompt.file) {
                watch(prompt.file)
                found.append(InstructionSource(origin: .codexPrompt, path: prompt.file.path, text: text, modifiedAt: Self.modified(prompt.file)))
            }
        }
        return found
    }

    private mutating func scanProject(_ id: UUID, file: URL, claude: (main: URL, nested: URL, local: URL), places: AgentLibraryPlaces) {
        for watched in [file, claude.main, claude.nested, claude.local] { watch(watched) }
        let text = Self.content(file)
        let linked = RelativeLink.points(claude.main, to: file)
        let others = (linked ? [claude.nested] : [claude.main, claude.nested]).filter(Self.exists)
        let claudeReads = linked || (!Self.exists(claude.local) && others.allSatisfy { Self.content($0) == text })
        if !claudeReads {
            let differing = others.compactMap { other in Self.content(other).flatMap { $0 == text ? nil : (other, $0) } }
            let sources = (text.map { [InstructionSource(origin: .shared, path: file.path, text: $0, modifiedAt: Self.modified(file))] } ?? [])
                + differing.map { InstructionSource(origin: .agent(.claudeCode), path: $0.0.path, text: $0.1, modifiedAt: Self.modified($0.0)) }
            if !sources.isEmpty { tidies.append(LibraryTidy(id: "project-claude/\(id.uuidString)", kind: .projectClaude(project: id, sources: sources))) }
        }
        let readers = text == nil ? [] : places.installed.filter { $0 != .claudeCode || claudeReads }
        instructions.append(LibraryInstruction(
            kind: .project(id), path: file.path, text: text, modifiedAt: Self.modified(file), readers: readers, links: linked ? [claude.main.path] : []))
    }

    static func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) || RelativeLink.isLink(file) }

    /// 盯文件与它所在的目录（文件换成链接、被删时目录里会变）。
    private mutating func watch(_ file: URL) {
        watched.insert(file.path)
        watched.insert(file.deletingLastPathComponent().path)
    }

    static func read(_ file: URL) -> String? { (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) } }

    /// 一份规则的正文：空的（0 字节、只有空白）等同没有——不算哪家写了一份、不进合并，项目里写"还没有"。
    static func content(_ file: URL) -> String? {
        read(file).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.realPath.path))?[.modificationDate] as? Date
    }
}

/// Codex 配置（`config.toml`）顶层的 `model_instructions_file`：它指的文件替换 Codex 的基础提示。只认第一个表头之前、带引号的那一行。
struct CodexPromptKey {
    let config: URL
    let file: URL
    /// 那一行在配置里的范围（撤掉这个键就是删掉这一行）
    let line: Range<String.Index>
    let text: String

    init?(_ places: AgentLibraryPlaces) {
        config = places.codexConfig
        guard let text = LibraryInstructionScan.read(config) else { return nil }
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[start..<end]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { return nil }
            if let match = line.firstMatch(of: /^\s*model_instructions_file\s*=\s*(["'])(.*)\1\s*(#.*)?$/.anchorsMatchLineEndings()) {
                let path = (String(match.2) as NSString).expandingTildeInPath
                file = path.hasPrefix("/") ? URL(filePath: path) : places.paths.home(of: .codex).appending(path: path)
                self.line = start..<end
                self.text = text
                return
            }
            start = end
        }
        return nil
    }

    /// 撤掉这个键之后的配置。
    var removed: String { text.replacingCharacters(in: line, with: "") }
}
#endif
