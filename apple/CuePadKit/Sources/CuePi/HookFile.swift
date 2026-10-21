#if os(macOS)
import CueStore
import Foundation

/// Claude Code、Codex 的钩子配置：CuePad 的条目合并进用户自己的配置文件（别人的条目原样留着），卸载只删 CuePad 的条目。
/// 认 CuePad 的条目只看命令（`<cuepad> hook <agent>`，路径可能是旧位置）。
protocol AgentHookConfig: Sendable {
    /// CuePad 写的文件（不含 `files(command:)` 判定用的记录）：卸载删它们里 CuePad 的条目，界面据此说明会写哪里。
    var writtenFiles: [URL] { get }
    /// 没有 CuePad 的条目为 `.missing`；条目齐全、命令就是 `command` 为 `.current`；其余（缺事件、旧路径、没被信任）为 `.outdated`。
    func files(command: String) -> AgentStatus.Files
    func install(command: String) async throws
    func uninstall() async throws
}

/// 一份 JSON 钩子配置文件里 CuePad 的条目（Claude Code 的 `settings.json`、Codex 的 `hooks.json`，两家同一种结构：
/// `{"hooks": {"<事件>": [{"matcher"?, "hooks": [{"type": "command", "command", "timeout", …}]}]}}`）。
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
        /// Agent 在等这个钩子时终端里那一行显示的话
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

    /// Claude Code：用户级的 `<配置目录>/settings.json`（Claude Code 把各层配置的钩子合并着跑）。
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

    /// 第一次装之前有什么、哪些结构是 CuePad 建的。
    struct Footprint: Codable, Equatable {
        /// 装之前文件在不在
        var file: Bool
        /// CuePad 建的 `hooks` 对象与事件数组
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

    /// CuePad 的一组：只有一条命令。
    func group(_ event: Event, command: String) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command, "timeout": event.timeout]
        if let message = event.statusMessage { handler["statusMessage"] = message }
        var group: [String: Any] = ["hooks": [handler]]
        if let matcher = event.matcher { group["matcher"] = matcher }
        return group
    }

    // MARK: 状态

    /// 只看文件：CuePad 的组与这个版本要写的逐组一致（事件、先后、内容）为 `.current`。
    func files(command: String) -> AgentStatus.Files {
        guard let text = try? Data(contentsOf: file), let tree = try? JSONSourceTree(text) else { return .missing }
        let ours = ourGroups(in: tree)
        guard !ours.isEmpty else { return .missing }
        let found = Dictionary(grouping: ours, by: \.event).mapValues { $0.compactMap { Self.json($0.node, in: text) as NSDictionary? } }
        let expected = Dictionary(grouping: events, by: \.name).mapValues { $0.map { group($0, command: command) as NSDictionary } }
        return found == expected ? .current : .outdated
    }

    /// CuePad 的组：所在事件、在该事件数组里的下标（Codex 信任的键要它），按文件里的先后。
    func ourGroups(in tree: JSONSourceTree) -> [(event: String, index: Int, node: JSONSourceTree.Node)] {
        (tree.root.member("hooks")?.members ?? []).flatMap { member in
            (member.value.elements ?? []).enumerated().filter { isOurs($0.element, in: tree.text) }.map { (member.key, $0.offset, $0.element) }
        }
    }

    // MARK: 安装与卸载

    /// 换成这个版本的条目：先删掉旧的组（结构留着），再按事件表追加；第一次装时记下装之前有什么。
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

    /// 删掉 CuePad 的组与它建的结构；装之前没有这个文件、删完只剩空对象的，删掉文件。最后删掉记录。
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

    // MARK: 条目

    /// `<…/cuepad> hook <agent>`：路径可能是 App 的旧位置，可能带引号。
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

    // MARK: 就地改写

    /// 删掉 CuePad 的组；`dropping` 里记着的 CuePad 建的事件数组与 `hooks` 因此空了也删掉（nil：结构都留着，升级时用）。
    /// 一次删一处、重新扫描，删法是插入的逆操作。
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

    /// 把组追加到各事件的数组末尾（没有这个事件、没有 `hooks` 就建上），插入紧凑的 JSON；一并给出新建了哪些结构。
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
    /// 文件不是 JSON 对象（写坏了）：不覆盖它
    case malformed(String)
    /// `hooks` 或其中某个事件不是对象、数组
    case unexpectedShape(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let path): "\(path) 不是有效的 JSON，CuePad 没有改它"
        case .unexpectedShape(let path): "\(path) 里的 hooks 格式不对，CuePad 没有改它"
        }
    }
}

/// JSON 原文里每个值的位置（字节区间），用来就地插入、删除而不重写整份文件。
struct JSONSourceTree {
    let text: Data
    let root: Node

    struct Node {
        var range: Range<Int>
        /// 对象的成员（键与键的起点）；不是对象为 nil
        var memberList: [(key: String, keyStart: Int, value: Node)]?
        var elements: [Node]?

        var members: [(key: String, keyStart: Int, value: Node)] { memberList ?? [] }

        func member(_ key: String) -> Node? { memberList?.last { $0.key == key }?.value }

        /// 删一个元素：有前一个就连同它之后的逗号一起删到这个元素末尾（插入的逆操作），否则删到下一个元素开头。
        func removing(element index: Int, in text: Data) -> Data {
            let items = elements ?? []
            let range = index > 0 ? items[index - 1].range.upperBound..<items[index].range.upperBound
                : items.count > 1 ? items[index].range.lowerBound..<items[index + 1].range.lowerBound
                : items[index].range
            return Self.removing(range, from: text)
        }

        func removing(member key: String, in text: Data) -> Data {
            let items = members
            guard let index = items.lastIndex(where: { $0.key == key }) else { return text }
            let range = index > 0 ? items[index - 1].value.range.upperBound..<items[index].value.range.upperBound
                : items.count > 1 ? items[index].keyStart..<items[index + 1].keyStart
                : items[index].keyStart..<items[index].value.range.upperBound
            return Self.removing(range, from: text)
        }

        /// 在最后一个元素之后插（`,<元素>`），空数组插在 `[` 之后。
        func insertion(element: String) -> (at: Int, text: String) {
            guard let last = elements?.last else { return (range.lowerBound + 1, element) }
            return (last.range.upperBound, "," + element)
        }

        func insertion(member: String) -> (at: Int, text: String) {
            guard let last = memberList?.last else { return (range.lowerBound + 1, member) }
            return (last.value.range.upperBound, "," + member)
        }

        func inserting(member: String, in text: Data) -> Data {
            let edit = insertion(member: member)
            var result = text
            result.insert(contentsOf: Data(edit.text.utf8), at: result.startIndex + edit.at)
            return result
        }

        private static func removing(_ range: Range<Int>, from text: Data) -> Data {
            var result = text
            result.removeSubrange((result.startIndex + range.lowerBound)..<(result.startIndex + range.upperBound))
            return result
        }
    }

    struct Malformed: Error {}

    init(_ text: Data) throws {
        self.text = text
        var scanner = Scanner(bytes: [UInt8](text))
        scanner.skipSpace()
        root = try scanner.value()
        guard root.memberList != nil else { throw Malformed() }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> Node {
            guard index < bytes.count else { throw Malformed() }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(String, Int, Node)] = []
                skipSpace()
                if peek(UInt8(ascii: "}")) { index += 1; return Node(range: start..<index, memberList: []) }
                while true {
                    skipSpace()
                    let keyStart = index
                    try string()
                    guard let key = (try? JSONSerialization.jsonObject(with: Data(bytes[keyStart..<index]), options: .fragmentsAllowed)) as? String
                    else { throw Malformed() }
                    skipSpace()
                    try expect(UInt8(ascii: ":"))
                    skipSpace()
                    members.append((key, keyStart, try value()))
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { index += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return Node(range: start..<index, memberList: members.map { (key: $0.0, keyStart: $0.1, value: $0.2) })
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [Node] = []
                skipSpace()
                if peek(UInt8(ascii: "]")) { index += 1; return Node(range: start..<index, elements: []) }
                while true {
                    skipSpace()
                    elements.append(try value())
                    skipSpace()
                    if peek(UInt8(ascii: ",")) { index += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return Node(range: start..<index, elements: elements)
                }
            case UInt8(ascii: "\""):
                try string()
            default:
                while index < bytes.count, !",]} \t\r\n".utf8.contains(bytes[index]) { index += 1 }
                guard index > start else { throw Malformed() }
            }
            return Node(range: start..<index)
        }

        private func peek(_ byte: UInt8) -> Bool { index < bytes.count && bytes[index] == byte }

        private mutating func expect(_ byte: UInt8) throws {
            guard peek(byte) else { throw Malformed() }
            index += 1
        }

        private mutating func string() throws {
            try expect(UInt8(ascii: "\""))
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): index += 1; return
                default: index += 1
                }
            }
            throw Malformed()
        }
    }
}
#endif
