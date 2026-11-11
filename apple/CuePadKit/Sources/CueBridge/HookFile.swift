#if os(macOS)
import CueStore
import Foundation

/// CuePad 的条目合并进用户自己的配置文件（别人的条目原样留着），卸载只删 CuePad 的条目，认 CuePad 的条目只看命令（`<cuepad> hook <agent>`，路径可能是旧位置）；
/// Pi 的是整个桥扩展目录（`PiExtensionFiles`，不看命令）。
protocol AgentHookConfig: Sendable {
    /// 不含 `files(command:)` 判定用的记录。
    var writtenFiles: [URL] { get }
    func files(command: String) -> AgentStatus.Files
    func install(command: String) async throws
    func uninstall() async throws
}

/// Claude Code 的 `settings.json`、Codex 的 `hooks.json` 两家同一种结构：
/// `{"hooks": {"<事件>": [{"matcher"?, "hooks": [{"type": "command", "command", "timeout", …}]}]}}`。
///
/// - 每个事件一组，追加在用户已有的组之后；文件按原文就地插入、删除（`JSONSourceTree`），用户的格式、键序与未知键一字不动。
/// - 卸载后与装之前逐字节一致：CuePad 建的结构（文件、`hooks`、事件数组）空了一并删掉，用户原有的空结构留着。哪些是 CuePad 建的
///   从文件本身看不出来（用户的 `"Stop": []` 插进一组后与 CuePad 新建的一模一样），所以第一次装时记下装之前有什么（`Footprint`，
///   放在 CuePad 自己的技能目录里，卸载时删掉）。记录丢了时什么结构都当作用户的，卸载只删组。
/// - 用户的文件不是 JSON 对象、`hooks` 或事件的形状不对时不改它、抛错。
struct HookFile: AgentHookConfig {
    struct Event: Sendable {
        var name: String
        /// 只对这些工具（或 MCP 服务）触发；nil 是全部
        var matcher: String? = nil
        /// 秒：放行的事件 CuePad 收到就回，CuePad 卡住时也不让 Agent 等太久；要等人作答的给足一天
        var timeout: Int
        var statusMessage: String? = nil
    }

    let agent: AgentKind
    let file: URL
    let footprintFile: URL
    let events: [Event]

    init(agent: AgentKind, file: URL, skillDirectory: URL, events: [Event]) {
        self.agent = agent
        self.file = file
        footprintFile = skillDirectory.appending(path: "\(agent.rawValue)-hooks.json")
        self.events = events
    }

    /// Claude Code 把各层配置的钩子合并着跑，所以写用户级的 `<配置目录>/settings.json`。
    /// 上报状态的事件同步跑（保持先后），CuePad 当场放行；要人作答的挡住等 CuePad 答复：权限确认（终端里同时照常弹出，哪边先答算哪边）、
    /// AskUserQuestion（官方的作答路径是它的 PreToolUse：返回 allow 与带答案的 `updatedInput`；PermissionRequest 会不会为它触发文档没写）、MCP 服务要你填的表单（Elicitation）。
    /// 一次工具调用只触发一组：其余工具的 PreToolUse 用排除 AskUserQuestion 的正则（Claude Code 的 matcher 是 JavaScript 正则）。
    static func claudeCode(home: URL, skillDirectory: URL) -> HookFile {
        let quick = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure",
                     "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "PostModelSwitch", "ElicitationResult"]
        let events = quick.map { Event(name: $0, timeout: 10) } + [
            Event(name: "PreToolUse", matcher: "^(?!AskUserQuestion$)", timeout: 10),
            Event(name: "PreToolUse", matcher: "AskUserQuestion", timeout: 86_400),
            Event(name: "PermissionRequest", timeout: 86_400),
            Event(name: "Elicitation", timeout: 86_400),
        ]
        return HookFile(agent: .claudeCode, file: home.appending(path: "settings.json"), skillDirectory: skillDirectory, events: events)
    }

    var writtenFiles: [URL] { [file] }

    struct Footprint: Codable, Equatable {
        var file: Bool
        var hooksObject = false
        var events: [String] = []
        /// Codex 的信任写在另一个文件（`config.toml`）里，它装之前的样子（`CodexHooks`）
        var config: CodexHooks.ConfigFootprint?

        static let unknown = Footprint(file: true)
    }

    func footprint() -> Footprint? {
        (try? Data(contentsOf: footprintFile)).flatMap { try? JSONDecoder().decode(Footprint.self, from: $0) }
    }

    func save(_ footprint: Footprint) throws {
        try FileManager.default.createDirectory(at: footprintFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(footprint).write(to: footprintFile, options: .atomic)
    }

    func group(_ event: Event, command: String) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command, "timeout": event.timeout]
        if let message = event.statusMessage { handler["statusMessage"] = message }
        var group: [String: Any] = ["hooks": [handler]]
        if let matcher = event.matcher { group["matcher"] = matcher }
        return group
    }

    func files(command: String) -> AgentStatus.Files {
        guard let text = try? Data(contentsOf: file), let tree = try? JSONSourceTree(text) else { return .missing }
        let ours = ourGroups(in: tree)
        guard !ours.isEmpty else { return .missing }
        let found = Dictionary(grouping: ours, by: \.event).mapValues { $0.compactMap { Self.json($0.node, in: text) as NSDictionary? } }
        let expected = Dictionary(grouping: events, by: \.name).mapValues { $0.map { group($0, command: command) as NSDictionary } }
        return found == expected ? .current : .outdated
    }

    /// 下标是 Codex 信任的键要用的。
    func ourGroups(in tree: JSONSourceTree) -> [(event: String, index: Int, node: JSONSourceTree.Node)] {
        (tree.root.member("hooks")?.members ?? []).flatMap { member in
            (member.value.elements ?? []).enumerated().filter { isOurs($0.element, in: tree.text) }.map { (member.key, $0.offset, $0.element) }
        }
    }

    func install(command: String) throws {
        let original = try? Data(contentsOf: file)
        guard original.map({ (try? JSONSourceTree($0)) != nil }) ?? true else { throw HookFileError.malformed(file.path) }
        var footprint = footprint() ?? Footprint(file: original != nil)
        let kept = try removingOurs(from: original ?? Data("{}".utf8), dropping: nil)
        let appended = try appending(events.map { ($0.name, group($0, command: command)) }, to: kept)
        footprint.hooksObject = footprint.hooksObject || appended.createdHooks
        footprint.events += appended.createdEvents.filter { !footprint.events.contains($0) }
        try save(footprint)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if appended.text != original { try appended.text.write(to: file, options: .atomic) }
    }

    func uninstall() throws {
        let footprint = footprint() ?? .unknown
        if let original = try? Data(contentsOf: file) {
            guard (try? JSONSourceTree(original)) != nil else { throw HookFileError.malformed(file.path) }
            let text = try removingOurs(from: original, dropping: footprint)
            if !footprint.file, try JSONSourceTree(text).root.members.isEmpty {
                try FileManager.default.removeItem(at: file)
            } else if text != original {
                try text.write(to: file, options: .atomic)
            }
        }
        if FileManager.default.fileExists(atPath: footprintFile.path) { try FileManager.default.removeItem(at: footprintFile) }
    }

    /// 路径可能是 App 的旧位置，可能带引号。
    private func isOurCommand(_ command: String) -> Bool {
        let suffix = " hook \(agent.rawValue)"
        guard command.hasSuffix(suffix) else { return false }
        let executable = command.dropLast(suffix.count).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return URL(filePath: executable).lastPathComponent == "cuepad"
    }

    static func json(_ node: JSONSourceTree.Node, in text: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: text[node.range])) as? [String: Any]
    }

    private func isOurs(_ node: JSONSourceTree.Node, in text: Data) -> Bool {
        ((Self.json(node, in: text)?["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String).map(isOurCommand) ?? false }
    }

    /// `dropping` 为 nil 时结构都留着（升级时用）。一次删一处、重新扫描，删法是插入的逆操作。
    private func removingOurs(from text: Data, dropping footprint: Footprint?) throws -> Data {
        var text = text
        while true {
            let tree = try JSONSourceTree(text)
            guard let hooks = tree.root.member("hooks") else { return text }
            if let array = hooks.members.first(where: { $0.value.elements?.contains { isOurs($0, in: text) } == true })?.value {
                text = array.removing(element: array.elements!.firstIndex { isOurs($0, in: text) }!, in: text)
                continue
            }
            guard let footprint else { return text }
            if let event = hooks.members.first(where: { footprint.events.contains($0.key) && $0.value.elements?.isEmpty == true })?.key {
                text = hooks.removing(member: event, in: text)
            } else if footprint.hooksObject, hooks.members.isEmpty {
                return tree.root.removing(member: "hooks", in: text)
            } else {
                return text
            }
        }
    }

    private func appending(
        _ groups: [(event: String, group: [String: Any])], to text: Data
    ) throws -> (text: Data, createdHooks: Bool, createdEvents: [String]) {
        func encoded(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
        }
        let events = groups.reduce(into: [String]()) { if !$0.contains($1.event) { $0.append($1.event) } }
        func members(of event: String) -> [[String: Any]] { groups.filter { $0.event == event }.map(\.group) }
        let tree = try JSONSourceTree(text)
        guard let hooks = tree.root.member("hooks") else {
            let body = try events.map { try encoded($0) + ":" + encoded(members(of: $0)) }.joined(separator: ",")
            return (tree.root.inserting(member: "\"hooks\":{" + body + "}", in: text), true, events)
        }
        guard hooks.memberList != nil else { throw HookFileError.unexpectedShape(file.path) }
        var edits: [(at: Int, text: String)] = []
        var created: [(event: String, member: String)] = []
        for event in events {
            if let array = hooks.member(event) {
                guard array.elements != nil else { throw HookFileError.unexpectedShape(file.path) }
                // 同一事件的几组一次插进去（空数组里逐个插会缺逗号）
                edits.append(array.insertion(element: try members(of: event).map(encoded).joined(separator: ",")))
            } else {
                created.append((event, (try encoded(event)) + ":" + (try encoded(members(of: event)))))
            }
        }
        // 新建的事件一次插进去（空对象里逐个插会缺逗号）
        if !created.isEmpty { edits.append(hooks.insertion(member: created.map(\.member).joined(separator: ","))) }
        var result = text
        // 同一位置的插入按原顺序：从后往前插，同位置的后一个先插
        for edit in edits.enumerated().sorted(by: { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }).map(\.element) {
            result.insert(contentsOf: Data(edit.text.utf8), at: result.startIndex + edit.at)
        }
        return (result, false, created.map(\.event))
    }
}

enum HookFileError: Error, Equatable, LocalizedError {
    case malformed(String)
    case unexpectedShape(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let path): String(localized: "\(path) 不是有效的 JSON，CuePad 没有改它")
        case .unexpectedShape(let path): String(localized: "\(path) 里的 hooks 格式不对，CuePad 没有改它")
        }
    }
}
#endif
