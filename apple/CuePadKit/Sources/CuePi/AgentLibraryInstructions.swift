#if os(macOS)
import CueStore
import Foundation

/// 照文件读出说明与说明那两种要整理的（位置见 `AgentLibraryPlaces`）：
/// - 全局：链到 `~/.agents/AGENTS.md` 的几家读它；哪家还有自己的一份（或缺链接），就是"各写一份"——各家自己的那份、
///   共读的那份，连同替换基础提示的两份（Pi 的 SYSTEM.md、Codex 的 `model_instructions_file`）一起比；替换基础提示的两份自己不算问题。
///   指到别处的链接不碰。
/// - 项目：同层另有一份内容不同的 CLAUDE.md（不是链到 AGENTS.md 的）就是问题，有它 Claude Code 不读 AGENTS.md。
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
        let sharedText = Self.read(shared)
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
            } else if let text = Self.read(file) {
                sources.append(InstructionSource(origin: .agent(kind), path: file.path, text: text, modifiedAt: Self.modified(file)))
                unlinked = true
            } else {
                unlinked = true
            }
        }
        if places.uses(.opencode) {
            let own = places.globalFile(.opencode)
            watch(own)
            if !RelativeLink.isLink(own), let text = Self.read(own) {
                sources.append(InstructionSource(origin: .agent(.opencode), path: own.path, text: text, modifiedAt: Self.modified(own)))
                unlinked = true
            } else if readers.contains(.claudeCode) {
                readers.append(.opencode)
            }
        }
        if unlinked, !sources.isEmpty {
            tidies.append(LibraryTidy(id: "global-instructions", kind: .globalInstructions(sources + replacements(places))))
        }
        instructions.append(LibraryInstruction(
            kind: .global, path: shared.path, text: sharedText, modifiedAt: Self.modified(shared), readers: readers, links: links))
        if places.uses(.pi), let text = Self.read(places.piSystem) {
            instructions.append(LibraryInstruction(kind: .piSystem, path: places.piSystem.path, text: text, modifiedAt: Self.modified(places.piSystem), readers: [.pi]))
        }
    }

    /// 替换基础提示的两份（有才列）。
    private mutating func replacements(_ places: AgentLibraryPlaces) -> [InstructionSource] {
        var found: [InstructionSource] = []
        if places.uses(.pi) {
            watch(places.piSystem)
            if let text = Self.read(places.piSystem) {
                found.append(InstructionSource(origin: .piSystem, path: places.piSystem.path, text: text, modifiedAt: Self.modified(places.piSystem)))
            }
        }
        if places.uses(.codex) {
            watch(places.codexConfig)
            if let prompt = CodexPromptKey(places), let text = Self.read(prompt.file) {
                watch(prompt.file)
                found.append(InstructionSource(origin: .codexPrompt, path: prompt.file.path, text: text, modifiedAt: Self.modified(prompt.file)))
            }
        }
        return found
    }

    private mutating func scanProject(_ id: UUID, file: URL, claude: URL, places: AgentLibraryPlaces) {
        watch(file)
        watch(claude)
        let text = Self.read(file)
        var links: [String] = [], claudeReads = true
        if RelativeLink.points(claude, to: file) {
            links.append(claude.path)
        } else if let claudeText = Self.read(claude), claudeText != text {
            claudeReads = false
            let sources = (text.map { [InstructionSource(origin: .shared, path: file.path, text: $0, modifiedAt: Self.modified(file))] } ?? [])
                + [InstructionSource(origin: .agent(.claudeCode), path: claude.path, text: claudeText, modifiedAt: Self.modified(claude))]
            tidies.append(LibraryTidy(id: "project-claude/\(id.uuidString)", kind: .projectClaude(project: id, sources: sources)))
        }
        let readers = text == nil ? [] : places.installed.filter { $0 != .claudeCode || claudeReads }
        instructions.append(LibraryInstruction(kind: .project(id), path: file.path, text: text, modifiedAt: Self.modified(file), readers: readers, links: links))
    }

    /// 盯文件与它所在的目录（文件换成链接、被删时目录里会变）。
    private mutating func watch(_ file: URL) {
        watched.insert(file.path)
        watched.insert(file.deletingLastPathComponent().path)
    }

    static func read(_ file: URL) -> String? { (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) } }

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
