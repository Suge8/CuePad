#if os(macOS)
import CueStore
import Foundation

struct LibraryInstructionScan {
    var instructions: [LibraryInstruction] = []
    var texts: [String: String] = [:]
    var tidies: [LibraryTidy] = []
    var watched: Set<String> = []
    /// 全局规则那件整理在：它会把 Claude Code 自己的全局 CLAUDE.md 并掉、移走（项目那边据此不另建链接）
    private var globalTidy = false

    init(_ places: AgentLibraryPlaces) {
        scanGlobal(places)
        for scope in places.scopes {
            guard case .project(let id) = scope, let file = places.projectInstructions(id), let claude = places.projectClaude(id) else { continue }
            scanProject(id, file: file, claude: claude, places: places)
        }
    }

    /// 列出各家此刻真读的：链到共享那份的算它的读者，别的各列一行（`.agent`）；会被整理并掉的那几份也是合并的来源。
    private mutating func scanGlobal(_ places: AgentLibraryPlaces) {
        let shared = places.globalInstructions
        let sharedText = LibraryFileReading.content(shared)
        var sources: [InstructionSource] = sharedText.map { [source(.shared, shared, $0)] } ?? []
        var readers: [AgentKind] = [], links: [String] = [], unlinked = false
        watch(shared)
        for kind in places.installed {
            kind.facts.globalReads.forEach { watch(places.paths.home(of: kind).appending(path: $0)) }
            let link = places.globalFile(kind)
            if places.globalReads(kind).contains(link), RelativeLink.points(link, to: shared) {
                if sharedText != nil { readers.append(kind) }
                links.append(link.path)
            } else {
                unlinked = true
            }
        }
        if places.uses(.claudeCode) { watch(places.paths.home(of: .claudeCode).appending(path: "AGENTS.md")) }
        if let claude = places.grokClaude, places.uses(.grok) { ["CLAUDE.md", "AGENTS.md", "rules/AGENTS.md"].forEach { watch(claude.appending(path: $0)) } }
        for file in places.globalFiles {
            watch(file.url)
            if file.retires { unlinked = true }
            guard !RelativeLink.points(file.url, to: shared), let text = LibraryFileReading.content(file.url) else { continue }
            if file.retires { sources.append(source(.agent(file.owner), file.url, text)) }
            add(.agent(file.owner, file: file.name), file.url, text, readers: file.readers)
        }
        let replacements = replacements(places)
        if unlinked, !sources.isEmpty {
            globalTidy = true
            tidies.append(LibraryTidy(id: "global-instructions", kind: .globalInstructions(sources + replacements)))
        }
        add(.global, shared, sharedText, readers: readers, links: links)
        if places.uses(.pi), let text = LibraryFileReading.content(places.piSystem) { add(.piSystem, places.piSystem, text, readers: [.pi]) }
    }

    /// 替换基础提示的两份（有才列）；不论要不要比都盯着：SYSTEM.md 留着时是单独一份规则，Codex 的配置里加上这个键就有一份要比。
    private mutating func replacements(_ places: AgentLibraryPlaces) -> [InstructionSource] {
        var found: [InstructionSource] = []
        if places.uses(.pi) {
            watch(places.piSystem)
            if let text = LibraryFileReading.content(places.piSystem) {
                found.append(source(.piSystem, places.piSystem, text))
            }
        }
        if places.uses(.codex) {
            watch(places.codexConfig)
            if let prompt = CodexPromptKey(places), let text = LibraryFileReading.content(prompt.file) {
                watch(prompt.file)
                found.append(source(.codexPrompt, prompt.file, text))
            }
        }
        return found
    }

    private mutating func scanProject(_ id: UUID, file: URL, claude: (main: URL, nested: URL, local: URL), places: AgentLibraryPlaces) {
        for watched in [file, claude.main, claude.nested, claude.local] { watch(watched) }
        let text = LibraryFileReading.content(file)
        let linked = RelativeLink.points(claude.main, to: file)
        let others = (linked ? [claude.nested] : [claude.main, claude.nested]).filter(LibraryFileReading.exists)
        // 自己目录里没有 CLAUDE.md 一类时它读 AGENTS.md，但往上哪一层有就不读了；项目里有 CLAUDE.md（链到 AGENTS.md 也算）时两份都读（2.1.318 实测）。
        // 挡着的只是它自己的全局 CLAUDE.md（~/.claude 在 ~ 下）、又有全局规则那件整理时，那件把它并进共享那份、移走，这里不另在项目里建链接
        let local = LibraryFileReading.exists(claude.local)
        let above = others.isEmpty ? places.claudeAbove(file.deletingLastPathComponent()) : []
        let claudeReads = linked || (!local && above.isEmpty && others.allSatisfy { LibraryFileReading.content($0) == text })
        let ownGlobal = places.paths.home(of: .claudeCode).appending(path: "CLAUDE.md").standardizedFileURL
        let globalFixes = globalTidy && !local && !above.isEmpty && above.allSatisfy { $0.standardizedFileURL == ownGlobal }
        if !claudeReads, !globalFixes {
            let differing = others.compactMap { other in LibraryFileReading.content(other).flatMap { $0 == text ? nil : (other, $0) } }
            let sources = (text.map { [source(.shared, file, $0)] } ?? []) + differing.map { source(.agent(.claudeCode), $0.0, $0.1) }
            if !sources.isEmpty { tidies.append(LibraryTidy(id: "project-claude/\(id.uuidString)", kind: .projectClaude(project: id, sources: sources))) }
        }
        let readers = text == nil ? [] : places.installed.filter { $0 != .claudeCode || claudeReads }
        add(.project(id), file, text, readers: readers, links: linked ? [claude.main.path] : [])
    }

    private mutating func add(_ kind: LibraryInstruction.Kind, _ file: URL, _ text: String?, readers: [AgentKind], links: [String] = []) {
        if let text { texts[file.path] = text }
        instructions.append(LibraryInstruction(
            kind: kind, path: file.path, hash: text.map(LibraryEdit.base), modifiedAt: LibraryFileReading.modified(file), readers: readers, links: links))
    }

    private mutating func source(_ origin: InstructionSource.Origin, _ file: URL, _ text: String) -> InstructionSource {
        texts[file.path] = text
        return InstructionSource(origin: origin, path: file.path, hash: LibraryEdit.base(of: text), modifiedAt: LibraryFileReading.modified(file))
    }

    private mutating func watch(_ file: URL) {
        watched.insert(file.path)
        watched.insert(file.deletingLastPathComponent().path)
    }

}

/// Codex 配置（`config.toml`）顶层的 `model_instructions_file`：它指的文件替换 Codex 的基础提示。只认第一个表头之前、带引号的那一行。
struct CodexPromptKey {
    let config: URL
    let file: URL
    let line: Range<String.Index>
    let text: String

    init?(_ places: AgentLibraryPlaces) {
        config = places.codexConfig
        guard let text = LibraryFileReading.read(config) else { return nil }
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[start..<end]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { return nil }
            if let match = line.firstMatch(of: /^\s*model_instructions_file\s*=\s*(["'])(.*)\1\s*(#.*)?$/.anchorsMatchLineEndings()) {
                let path = places.paths.expanding(String(match.2))
                file = path.hasPrefix("/") ? URL(filePath: path) : places.paths.home(of: .codex).appending(path: path)
                self.line = start..<end
                self.text = text
                return
            }
            start = end
        }
        return nil
    }

    var removed: String { text.replacingCharacters(in: line, with: "") }
}
#endif
