#if os(macOS)
import CueStore
import Foundation

struct LibrarySkillScan {
    var skills: [LibrarySkill] = []
    var texts: [String: String] = [:]
    var tidies: [LibraryTidy] = []
    var selfManaged: [SelfManagedSkills] = []
    var watched: Set<String> = []

    struct Found {
        let entry: SkillEntry
        let group: String
        let text: String
        let modifiedAt: Date?
        let problem: SkillProblem?
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
            add(found, unseenBy: unseen)
        }
        let moved = Set(moves.map(\.skill.path))
        for found in strays where !moved.contains(found.entry.path) {
            add(found, unseenBy: found.problem == nil ? places.installed.filter { $0 != found.owner } : [])
        }
        for agent in AgentKind.allCases {
            if let entries = unlinked[agent] { tidies.append(LibraryTidy(id: "unlinked/\(agent.rawValue)", kind: .unlinked(agent: agent, skills: entries))) }
        }
        let scopes = places.scopes
        skills.sort { a, b in
            let order = { (skill: LibrarySkill) in (scopes.firstIndex(of: skill.scope) ?? 0, skill.group.isEmpty ? 1 : 0, skill.group, skill.name, skill.path) }
            return order(a) < order(b)
        }
        if !empties.isEmpty { tidies.append(LibraryTidy(id: "empty", kind: .empty(empties))) }
    }

    private mutating func add(_ found: Found, unseenBy: [AgentKind]) {
        let skill = LibrarySkill(
            name: found.entry.name, scope: found.entry.scope, group: found.group, path: found.entry.path,
            description: SkillDocument(found.text).description ?? "", hash: LibraryEdit.base(of: found.text), modifiedAt: found.modifiedAt,
            problem: found.problem, unseenBy: unseenBy)
        skills.append(skill)
        texts[skill.textPath] = found.text
    }

    /// 旧目录里的链接不碰（Claude Code 的技能链接、指到别处的）。
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
                    // 读不出（不是 UTF-8、没权限）的也是技能，格式不对；同改文件时的读法（`AgentLibraryFiles.write`），哈希才对得上
                    let text = LibraryFileReading.read(skillFile) ?? ""
                    watched.insert(skillFile.path)
                    found.append(Found(
                        entry: SkillEntry(name: name, scope: scope, path: item.path), group: group.joined(separator: "/"), text: text,
                        modifiedAt: LibraryFileReading.modified(skillFile), problem: SkillDocument(text).problem(directory: name, depth: group.count + 1)))
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

    /// 超过 6 层的技能也要找到、报出来（`SkillProblem.tooDeep`），再深的不找。
    private static let walkLimit = 8

    private static func entries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static func isManaged(_ name: String, in root: URL) -> Bool {
        AgentKind.allCases.contains { $0.facts.selfManagedSkills == name && root.lastPathComponent == "skills" }
    }

    /// Claude Code 的 `synced` 下先按账号分一层。找过的目录都盯着，没有技能时也盯着（Codex 的 `.system` 走不到 `walk`）：多了少了，计数跟着变。
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
    /// 取各家最严的那条。
    func problem(directory: String, depth: Int) -> SkillProblem? {
        guard let name, !name.isEmpty else { return .unreadable }
        if directory.count > 64 || !directory.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) { return .badName }
        if name != directory { return .nameMismatch(name) }
        guard let description, (1...1024).contains(description.count) else { return .badDescription }
        return depth > 6 ? .tooDeep : nil
    }
}
#endif
