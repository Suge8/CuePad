#if os(macOS)
import CueStore
import Foundation

/// 照文件读出技能与技能那几种该整理的（位置见 `AgentLibraryPlaces`）。规则：
/// - 有 `SKILL.md` 的目录是技能，不再往里找；没有的非空目录是分类（Claude Code、dsh 的目录只看一层），空的（只算 `.DS_Store` 也空）进"空目录"。
/// - 格式取四家最严（`SkillProblem`）：格式不对的照列成技能、带上哪里不对，不搬、不链、不算同名。
/// - 列出的技能：`.agents/skills` 里的全部，加旧目录里一键整理搬不走的（同名、格式不对的）；旧目录里的只有那一家读得到。
/// - 旧目录里的：不是 CuePad 的（旧版副本由接入收掉）、不是各家自管的（Claude Code 的 `skills/synced/<账号>/…`、Codex 的 `skills/.system`，只计数）；
///   链接不碰（Claude Code、dsh 目录里指到 `.agents` 的是它们的技能链接）。搬到同层 `.agents/skills` 下的同一分类。
/// - 同名：全局与项目之间、同一层里（旧目录里的按搬过去之后算）；两个项目各有一个不算。
/// - 读不到 `.agents` 里这一个的那家（`SharedSkills`）看不见：它用着、链接的位置还空着（那里已有别的东西不碰），每家一件。
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
        let problem: SkillProblem?
        /// 在旧目录里：哪家的、搬到这里
        var owner: AgentKind?
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
                    oldWalk.found[index].owner = old.agent
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
            tidies.append(LibraryTidy(id: id, kind: .duplicate(name: name, copies: copies.map(\.entry))))
        }
        let moves = strays.filter { $0.problem == nil && !duplicated.contains($0.entry.path) }.compactMap { found in
            found.moveTo.map { SkillMove(skill: found.entry, to: $0.path) }
        }
        if !moves.isEmpty { tidies.append(LibraryTidy(id: "stray", kind: .stray(moves))) }

        var unlinked: [AgentKind: [SkillEntry]] = [:]
        for found in shared {
            var unseen: [AgentKind] = []
            for (agent, link) in found.problem == nil ? places.links(found.entry.name, group: found.group, in: found.entry.scope) : []
            where !RelativeLink.points(link, to: URL(filePath: found.entry.path)) {
                unseen.append(agent)
                let free = !FileManager.default.fileExists(atPath: link.path) && !RelativeLink.isLink(link)
                if free, !duplicated.contains(found.entry.path) { unlinked[agent, default: []].append(found.entry) }
            }
            skills.append(Self.skill(found, unseenBy: unseen))
        }
        let moved = Set(moves.map(\.skill.path))
        for found in strays where !moved.contains(found.entry.path) {
            skills.append(Self.skill(found, unseenBy: found.problem == nil ? places.installed.filter { $0 != found.owner } : []))
        }
        for agent in AgentKind.allCases {
            if let entries = unlinked[agent] { tidies.append(LibraryTidy(id: "unlinked/\(agent.rawValue)", kind: .unlinked(agent: agent, skills: entries))) }
        }
        // 先全局、后各项目（同 `places.scopes`），每层按分类（不在分类里的最后）、名字、路径
        let scopes = places.scopes
        skills.sort { a, b in
            let order = { (skill: LibrarySkill) in (scopes.firstIndex(of: skill.scope) ?? 0, skill.group.isEmpty ? 1 : 0, skill.group, skill.name, skill.path) }
            return order(a) < order(b)
        }
        if !empties.isEmpty { tidies.append(LibraryTidy(id: "empty", kind: .empty(empties))) }
    }

    private static func skill(_ found: Found, unseenBy: [AgentKind]) -> LibrarySkill {
        LibrarySkill(
            name: found.entry.name, scope: found.entry.scope, group: found.group, path: found.entry.path, text: found.text,
            problem: found.problem, unseenBy: unseenBy)
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
                    // 读不出（不是 UTF-8、没权限）的也是技能，格式不对
                    let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
                    if inOldDirectory, name == AgentSkill.name, AgentSkill.kinds(in: text) != nil { continue }  // 旧版 CuePad 副本：接入收掉它
                    watched.insert(skillFile.path)
                    found.append(Found(
                        entry: SkillEntry(name: name, scope: scope, path: item.path), group: group.joined(separator: "/"), text: text,
                        problem: SkillDocument(text).problem(directory: name, depth: group.count + 1)))
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

extension SkillDocument {
    /// 四家最严的那条：名字 = 目录名、只用 `[a-z0-9-]`、不超过 64；说明 1–1024；嵌套不超过 6 层。对的为 nil。
    func problem(directory: String, depth: Int) -> SkillProblem? {
        guard let name, !name.isEmpty else { return .unreadable }
        if directory.count > 64 || !directory.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) { return .badName }
        if name != directory { return .nameMismatch(name) }
        guard let description, (1...1024).contains(description.count) else { return .badDescription }
        return depth > 6 ? .tooDeep : nil
    }
}
#endif
