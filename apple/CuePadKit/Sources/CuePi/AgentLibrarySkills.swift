#if os(macOS)
import CueStore
import Foundation

/// 照文件读出技能与技能那几种要整理的（位置见 `AgentLibraryPlaces`）。规则：
/// - 有 `SKILL.md` 的目录是技能，不再往里找；没有的非空目录是分类（Claude Code 的目录只看一层），空的（只算 `.DS_Store` 也空）进"空目录"。
/// - 格式取四家最严（`SkillProblem`）：格式不对的只进要整理，不列成技能、不搬、不链。
/// - 旧目录里的：不是 CuePad 的（旧版副本由接入收掉）、不是各家自管的（Claude Code 的 `skills/synced/<账号>/…`、Codex 的 `skills/.system`，只计数）；
///   链接不碰（Claude Code 目录里指到 `.agents` 的是它的技能链接）。搬到同层 `.agents/skills` 下的同一分类。
/// - 同名：全局与项目之间、同一层里（旧目录里的按搬过去之后算）；两个项目各有一个不算。
/// - Claude Code 看不见：它用着、链接的位置还空着（那里已有别的东西不碰）。
struct LibrarySkillScan {
    var skills: [LibrarySkill] = []
    var tidies: [LibraryTidy] = []
    var selfManaged: [SelfManagedSkills] = []
    var watched: Set<String> = []

    /// 一个技能目录（格式对不对都在）。
    struct Found {
        let entry: SkillEntry
        let group: String
        let text: String
        let modifiedAt: Date
        let frontmatter: SkillFrontmatter?
        let problem: SkillProblem?
        /// 在旧目录里：搬到这里
        var moveTo: URL?
    }

    init(_ places: AgentLibraryPlaces) {
        var shared: [Found] = [], strays: [Found] = [], empties: [String] = []
        for scope in places.scopes {
            guard let root = places.skills(scope) else { continue }
            let walked = walk(root, scope: scope, recursive: true, inOldDirectory: false)
            shared += walked.found
            empties += walked.empties
            for old in places.oldSkills(scope) {
                var oldWalk = walk(old.directory, scope: scope, recursive: old.recursive, inOldDirectory: true)
                empties += oldWalk.empties
                for index in oldWalk.found.indices {
                    let relative = oldWalk.found[index].group.isEmpty ? oldWalk.found[index].entry.name : oldWalk.found[index].group + "/" + oldWalk.found[index].entry.name
                    oldWalk.found[index].moveTo = root.appending(path: relative, directoryHint: .isDirectory)
                }
                strays += oldWalk.found
                if let managed = old.agent.facts.selfManagedSkills, scope == .global {
                    let count = managedCount(in: old.directory.appending(path: managed, directoryHint: .isDirectory))
                    if count > 0, !selfManaged.contains(where: { $0.agent == old.agent }) { selfManaged.append(SelfManagedSkills(agent: old.agent, count: count)) }
                }
            }
        }

        let valid = (shared + strays).filter { $0.problem == nil }
        let duplicates = Self.duplicates(valid)
        let duplicated = Set(duplicates.flatMap { $0.map(\.entry.path) })
        for copies in duplicates {
            let name = copies[0].entry.name
            let id = switch copies[0].entry.scope {
            case .global: "duplicate/\(name)"
            case .project(let project): "duplicate/\(name)/\(project.uuidString)"
            }
            tidies.append(LibraryTidy(id: id, kind: .duplicate(
                name: name, copies: copies.map { SkillCopy(skill: $0.entry, text: $0.text, modifiedAt: $0.modifiedAt) })))
        }
        let moves = strays.filter { $0.problem == nil && !duplicated.contains($0.entry.path) }.compactMap { found in
            found.moveTo.map { SkillMove(skill: found.entry, to: $0.path) }
        }
        if !moves.isEmpty { tidies.append(LibraryTidy(id: "stray", kind: .stray(moves))) }

        var unlinked: [SkillEntry] = []
        for found in shared where found.problem == nil && !duplicated.contains(found.entry.path) {
            let link = places.claudeSkills(found.entry.scope)?.appending(path: found.entry.name, directoryHint: .isDirectory)
            let linked = link.map { RelativeLink.points($0, to: URL(filePath: found.entry.path)) } ?? true
            let free = link.map { !FileManager.default.fileExists(atPath: $0.path) && !RelativeLink.isLink($0) } ?? false
            if !linked, free { unlinked.append(found.entry) }
            skills.append(LibrarySkill(
                name: found.entry.name, description: found.frontmatter?.description ?? "", scope: found.entry.scope, group: found.group,
                path: found.entry.path, unseenBy: linked ? [] : [.claudeCode]))
        }
        if !unlinked.isEmpty { tidies.append(LibraryTidy(id: "unlinked", kind: .unlinked(unlinked))) }
        // 先全局、后各项目（同 `places.scopes`），每层按分类（不在分类里的最后）、名字
        let scopes = places.scopes
        skills.sort { a, b in
            let order = { (skill: LibrarySkill) in (scopes.firstIndex(of: skill.scope) ?? 0, skill.group.isEmpty ? 1 : 0, skill.group, skill.name) }
            return order(a) < order(b)
        }
        for found in shared + strays {
            guard let problem = found.problem else { continue }
            tidies.append(LibraryTidy(id: "malformed/\(found.entry.path)", kind: .malformed(found.entry, problem)))
        }
        if !empties.isEmpty { tidies.append(LibraryTidy(id: "empty", kind: .empty(empties))) }
    }

    /// 走一个技能目录：读出技能与空目录，记下要盯的目录与文件。旧目录里的链接不碰（Claude Code 的技能链接、指到别处的）。
    private mutating func walk(_ root: URL, scope: LibraryScope, recursive: Bool, inOldDirectory: Bool) -> (found: [Found], empties: [String]) {
        var found: [Found] = [], empties: [String] = []
        watched.insert(root.path)
        func visit(_ directory: URL, group: [String]) {
            for name in Self.entries(directory) where !name.hasPrefix(".") {
                let item = directory.appending(path: name, directoryHint: .isDirectory)
                if inOldDirectory, RelativeLink.isLink(item) { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                watched.insert(item.path)  // 各家自管的目录也盯着：里面多了少了，计数跟着变
                if inOldDirectory, group.isEmpty, Self.isManaged(name, in: root) { continue }
                let skillFile = item.appending(path: AgentSkill.fileName)
                if FileManager.default.fileExists(atPath: skillFile.path) {
                    // 读不出（不是 UTF-8、没权限）的也是技能，格式不对：进要整理
                    let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
                    if inOldDirectory, name == AgentSkill.name, AgentSkill.kinds(in: text) != nil { continue }  // 旧版 CuePad 副本：接入收掉它
                    watched.insert(skillFile.path)
                    let frontmatter = SkillFrontmatter(text)
                    let modified = (try? skillFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    found.append(Found(
                        entry: SkillEntry(name: name, scope: scope, path: item.path), group: group.joined(separator: "/"), text: text,
                        modifiedAt: modified, frontmatter: frontmatter, problem: SkillFrontmatter.problem(frontmatter, directory: name, depth: group.count + 1)))
                } else if Self.entries(item).allSatisfy({ $0 == ".DS_Store" }) {
                    empties.append(item.path)
                } else if recursive, group.count < Self.walkLimit {
                    visit(item, group: group + [name])
                }
            }
        }
        visit(root, group: [])
        return (found, empties)
    }

    /// 往下找的层数上限：超过 6 层的技能也要找到、报出来（`SkillProblem.tooDeep`），再深的不找。
    private static let walkLimit = 8

    private static func entries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// 各家自管、不碰的目录（只在它自己的全局技能目录下一层）。
    private static func isManaged(_ name: String, in root: URL) -> Bool {
        AgentKind.allCases.contains { $0.facts.selfManagedSkills == name && root.lastPathComponent == "skills" }
    }

    /// 各家自管目录里有几个技能：有 SKILL.md 的目录算一个，没有的往下找（Claude Code 的 `synced` 下先按账号分一层）。
    /// 找过的目录都盯着，没有技能时也盯着（Codex 的 `.system` 走不到 `walk`）：多了少了，计数跟着变。
    private mutating func managedCount(in directory: URL) -> Int {
        var count = 0
        func visit(_ directory: URL, depth: Int) {
            watched.insert(directory.path)
            for name in Self.entries(directory) where !name.hasPrefix(".") {
                let item = directory.appending(path: name, directoryHint: .isDirectory)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if FileManager.default.fileExists(atPath: item.appending(path: AgentSkill.fileName).path) {
                    count += 1
                } else if depth < Self.walkLimit {
                    visit(item, depth: depth + 1)
                }
            }
        }
        visit(directory, depth: 0)
        return count
    }

    /// 同名的几组（每组先全局、后各项目，按路径）：有全局的，连同各项目里同名的一组（留下哪份只移走和它撞名的，`LibraryTidying`）；
    /// 没有全局的，同一个项目里两个以上才算，每个项目一组——两个项目各有一个不撞名。
    private static func duplicates(_ skills: [Found]) -> [[Found]] {
        Dictionary(grouping: skills, by: \.entry.name).sorted { $0.key < $1.key }.flatMap { _, copies -> [[Found]] in
            let sorted = copies.sorted { ($0.entry.scope == .global ? 0 : 1, $0.entry.path) < ($1.entry.scope == .global ? 0 : 1, $1.entry.path) }
            if sorted.contains(where: { $0.entry.scope == .global }) { return sorted.count > 1 ? [sorted] : [] }
            return byProject(sorted)
        }
    }

    private static func byProject(_ copies: [Found]) -> [[Found]] {
        var groups: [LibraryScope: [Found]] = [:], order: [LibraryScope] = []
        for copy in copies {
            if groups[copy.entry.scope] == nil { order.append(copy.entry.scope) }
            groups[copy.entry.scope, default: []].append(copy)
        }
        return order.compactMap { groups[$0].flatMap { $0.count > 1 ? $0 : nil } }
    }
}

/// SKILL.md 开头 `---` 之间的名字与说明（YAML 的简单写法：`键: 值`，带引号的去掉引号，`|`、`>` 与空值接着读缩进的几行）。
struct SkillFrontmatter: Equatable {
    var name: String?
    var description: String?

    init?(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var fields: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = !value.hasPrefix("|")
                var parts: [String] = []
                while index < end, lines[index].isEmpty || lines[index].first == " " || lines[index].first == "\t" {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = parts.joined(separator: folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = value
        }
        name = fields["name"]
        description = fields["description"]
    }

    /// 四家最严的那条：名字 = 目录名、只用 `[a-z0-9-]`、不超过 64；说明 1–1024；嵌套不超过 6 层。对的为 nil。
    static func problem(_ frontmatter: SkillFrontmatter?, directory: String, depth: Int) -> SkillProblem? {
        guard let frontmatter, let name = frontmatter.name, !name.isEmpty else { return .unreadable }
        if directory.count > 64 || !directory.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) { return .badName }
        if name != directory { return .nameMismatch(name) }
        guard let description = frontmatter.description, (1...1024).contains(description.count) else { return .badDescription }
        return depth > 6 ? .tooDeep : nil
    }
}
#endif
