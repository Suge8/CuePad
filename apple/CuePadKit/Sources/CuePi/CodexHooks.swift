#if os(macOS)
import CryptoKit
import CueStore
import Foundation

/// Codex 的钩子：CuePad 的条目写在 `<CODEX_HOME>/hooks.json`，信任记在 `config.toml` 的 `[hooks.state]`（经 `codex app-server` 的 `config/batchWrite` 写）。
///
/// - 每个事件一组，追加在用户已有的组之后；文件按原文就地插入、删除，用户的格式、键序与未知键一字不动，卸载后与装之前逐字节一致。
/// - Codex 只执行被信任的钩子：信任条目的键是"hooks.json 的真实路径:事件:组号:条目号"，值是条目内容的哈希。装时向 Codex 要
///   （`hooks/list` 给出键与哈希，`config/batchWrite` 写入，和 `/hooks` 里点信任同一条路）；查状态不起进程，按 Codex 的规则自己算
///   （`hook_hash`：事件名与只含这一条的组，转成键排好序的紧凑 JSON 取 SHA-256），与 `config.toml` 里的比——对不上（没信任、
///   用户删了排在前面的组使组号变了、Codex 改了算法）就是旧版，重装时重新信任。
/// - 卸载删掉 CuePad 的信任条目（`config/batchWrite` 对带引号的键写 null）。CuePad 建的结构（文件、`hooks`、事件数组、
///   `[hooks]`、`[hooks.state]`）空了一并删掉，用户原有的空结构留着：哪些是 CuePad 建的从文件本身看不出来（用户的 `"Stop": []`
///   插进一组后与 CuePad 新建的一模一样），所以第一次装时记下装之前有什么（`Footprint`，放在 CuePad 自己的技能目录里，卸载时删掉）。
struct CodexHooks: AgentHookConfig {
    let home: URL
    let locator: ExecutableLocator
    /// 起 codex 时的基础环境（`AgentPaths.environment`），在它之上换掉配置目录与查找路径
    let environment: [String: String]

    /// 全部 12 个事件；权限确认要等 CuePad 作答（远程的回答可能很久才来，超时后 Codex 当作钩子没给决定，回到终端里问），
    /// 会话结束与中断 Codex 最多给 3 秒，其余当场就回。
    static let events: [(name: String, label: String, timeout: Int)] = [
        ("SessionStart", "session_start", 10), ("UserPromptSubmit", "user_prompt_submit", 10), ("PreToolUse", "pre_tool_use", 10),
        ("PermissionRequest", "permission_request", 86_400), ("PostToolUse", "post_tool_use", 10), ("PreCompact", "pre_compact", 10),
        ("PostCompact", "post_compact", 10), ("SubagentStart", "subagent_start", 10), ("SubagentStop", "subagent_stop", 10),
        ("Stop", "stop", 10), ("Interrupt", "interrupt", 3), ("SessionEnd", "session_end", 3),
    ]

    /// 权限确认的钩子挂住等 CuePad 时（人不在这台 Mac 前），Codex 终端里那一行显示它（钩子拿着这次确认，终端里不弹框）。
    static let waitingMessage = "等你在 CuePad 里确认"

    private var hooksFile: URL { home.appending(path: "hooks.json") }
    private var configFile: URL { home.appending(path: "config.toml") }
    private var footprintFile: URL { home.appending(path: "skills/\(AgentSkill.name)/codex-hooks.json") }

    /// 第一次装之前有什么、哪些结构是 CuePad 建的。没有记录（被删了）时什么结构都当作用户的，卸载只删组与信任条目。
    struct Footprint: Codable, Equatable {
        /// 装之前 hooks.json、config.toml 在不在
        var hooksFile: Bool
        var configFile: Bool
        /// CuePad 在 hooks.json 里建的 `hooks` 对象与事件数组
        var hooksObject = false
        var events: [String] = []
        /// CuePad 在 config.toml 里建的 `[hooks]`、`[hooks.state]`；第一次写信任时才知道
        var hooksTable: Bool?
        var stateTable: Bool?

        static let unknown = Footprint(hooksFile: true, configFile: true)
    }

    private func footprint() -> Footprint? {
        (try? Data(contentsOf: footprintFile)).flatMap { try? JSONDecoder().decode(Footprint.self, from: $0) }
    }

    private func save(_ footprint: Footprint) throws {
        try FileManager.default.createDirectory(at: footprintFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(footprint).write(to: footprintFile, options: .atomic)
    }

    // MARK: 状态

    func files(command: String) -> AgentStatus.Files {
        guard let text = try? Data(contentsOf: hooksFile), let tree = try? CodexJSONTree(text), !Self.ours(in: tree).isEmpty else { return .missing }
        let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let path = Self.realPath(hooksFile)
        for event in Self.events {
            let groups = Self.groups(of: event.name, in: tree)
            let mine = groups.indices.filter { Self.isOurs(groups[$0], in: text) }
            guard mine.count == 1, let index = mine.first,
                  NSDictionary(dictionary: Self.json(groups[index], in: text) ?? [:]).isEqual(to: Self.group(event, command: command)),
                  Self.trustedHash(of: Self.key(path, event.label, index), in: config) == Self.hash(event, command: command)
            else { return .outdated }
        }
        return .current
    }

    // MARK: 安装与卸载

    func install(command: String) async throws {
        let original = try? Data(contentsOf: hooksFile)
        guard original.map({ (try? CodexJSONTree($0)) != nil }) ?? true else { throw CodexHooksError.malformed }
        var footprint = footprint()
            ?? Footprint(hooksFile: original != nil, configFile: FileManager.default.fileExists(atPath: configFile.path))
        let kept = try Self.removingOurs(from: original ?? Data("{}".utf8), dropping: nil)
        let appended = try Self.appending(Self.events.map { ($0.name, Self.group($0, command: command)) }, to: kept)
        footprint.hooksObject = footprint.hooksObject || appended.createdHooks
        footprint.events += appended.createdEvents.filter { !footprint.events.contains($0) }
        try save(footprint)
        if appended.text != original { try appended.text.write(to: hooksFile, options: .atomic) }
        try await trust(command: command, footprint: footprint)
        guard files(command: command) == .current else { throw CodexHooksError.notTrusted }
    }

    func uninstall() async throws {
        let footprint = footprint() ?? .unknown
        guard let original = try? Data(contentsOf: hooksFile) else { return try forgetFootprint() }
        guard let tree = try? CodexJSONTree(original) else { throw CodexHooksError.malformed }
        let path = Self.realPath(hooksFile)
        let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let keys = Self.events.flatMap { event in
            let groups = Self.groups(of: event.name, in: tree)
            return groups.indices.filter { Self.isOurs(groups[$0], in: original) }.map { Self.key(path, event.label, $0) }
        }.filter { Self.trustedHash(of: $0, in: config) != nil }
        if !keys.isEmpty { try await untrust(keys, footprint: footprint) }
        let text = try Self.removingOurs(from: original, dropping: footprint)
        if !footprint.hooksFile, (try CodexJSONTree(text)).root.members.isEmpty {
            try FileManager.default.removeItem(at: hooksFile)
        } else if text != original {
            try text.write(to: hooksFile, options: .atomic)
        }
        try forgetFootprint()
    }

    private func forgetFootprint() throws {
        if FileManager.default.fileExists(atPath: footprintFile.path) { try FileManager.default.removeItem(at: footprintFile) }
    }

    /// 让 Codex 信任 CuePad 的条目：它列出的键与哈希原样写回。第一次写之前记下 `[hooks]`、`[hooks.state]` 原来在不在。
    private func trust(command: String, footprint: Footprint) async throws {
        try await withCodex { rpc in
            let list = try await rpc.call("hooks/list", ["cwds": [home.path]])
            let listed = (list["data"] as? [CodexRPC.Object])?.first
            let entries = (listed?["hooks"] as? [CodexRPC.Object]) ?? []
            guard entries.contains(where: { $0["command"] as? String == command }) else {
                throw CodexHooksError.rejected(((listed?["warnings"] as? [String]) ?? []).joined(separator: "；"))
            }
            var state: CodexRPC.Object = [:]
            for entry in entries where entry["command"] as? String == command && entry["trustStatus"] as? String != "trusted" {
                guard let key = entry["key"] as? String, let hash = entry["currentHash"] as? String else { continue }
                state[key] = ["trusted_hash": hash]
            }
            guard !state.isEmpty else { return }
            if footprint.stateTable == nil {
                let hooks = try await userHooks(rpc)
                var updated = footprint
                updated.hooksTable = hooks == nil
                updated.stateTable = hooks?["state"] == nil
                try save(updated)
            }
            try await rpc.call("config/batchWrite", ["edits": [["keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"]]])
        }
    }

    /// 删掉这些信任条目；CuePad 建的 `[hooks.state]` 因此空了就删掉它，CuePad 建的 `[hooks]` 也只剩它就一并删掉。
    /// 装之前没有 `config.toml`、删完只剩空白的，删掉文件。
    private func untrust(_ keys: [String], footprint: Footprint) async throws {
        try await withCodex { rpc in
            let hooks = try await userHooks(rpc) ?? [:]
            let state = hooks["state"] as? CodexRPC.Object ?? [:]
            var edits: [CodexRPC.Object] = keys.map { ["keyPath": "hooks.state.\(Self.quoted($0))", "value": NSNull(), "mergeStrategy": "replace"] }
            if footprint.stateTable == true, Set(state.keys).isSubset(of: keys) {
                edits.append(["keyPath": "hooks.state", "value": NSNull(), "mergeStrategy": "replace"])
                if footprint.hooksTable == true, hooks.keys.allSatisfy({ $0 == "state" }) {
                    edits.append(["keyPath": "hooks", "value": NSNull(), "mergeStrategy": "replace"])
                }
            }
            try await rpc.call("config/batchWrite", ["edits": edits])
        }
        if !footprint.configFile, let left = try? String(contentsOf: configFile, encoding: .utf8), left.allSatisfy(\.isWhitespace) {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    /// 用户层 `config.toml` 里的 `[hooks]`（不含别的层与缺省值）；没有为 nil。
    @MainActor private func userHooks(_ rpc: CodexRPC) async throws -> CodexRPC.Object? {
        let read = try await rpc.call("config/read", ["includeLayers": true])
        let user = (read["layers"] as? [CodexRPC.Object])?.first { ($0["name"] as? CodexRPC.Object)?["type"] as? String == "user" }
        return (user?["config"] as? CodexRPC.Object)?["hooks"] as? CodexRPC.Object
    }

    /// 起一个指向这个配置目录的 `codex app-server`，用完关掉并等它退出。
    private func withCodex(_ body: @MainActor (CodexRPC) async throws -> Void) async throws {
        guard let codex = locator.candidates(AgentKind.codex.command).first else { throw CodexHooksError.codexNotFound }
        var environment = environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = locator.path
        try await Self.run(codex, environment, body)
    }

    @MainActor private static func run(
        _ codex: URL, _ environment: [String: String], _ body: @MainActor (CodexRPC) async throws -> Void
    ) async throws {
        let rpc = try await CodexRPC.launch(codex, environment: environment)
        do {
            try await body(rpc)
        } catch {
            await rpc.shutdown()
            throw error
        }
        await rpc.shutdown()
    }

    // MARK: 条目

    /// CuePad 的一组：只有一条命令（`<cuepad> hook codex`）。
    static func group(_ event: (name: String, label: String, timeout: Int), command: String) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command, "timeout": event.timeout]
        if event.name == "PermissionRequest" { handler["statusMessage"] = waitingMessage }
        return ["hooks": [handler]]
    }

    /// Codex 的信任哈希（`hook_hash`）：条目按 Codex 读进来的样子补全（`async` 缺省 false）。
    static func hash(_ event: (name: String, label: String, timeout: Int), command: String) -> String? {
        guard var handler = (group(event, command: command)["hooks"] as? [[String: Any]])?.first else { return nil }
        handler["async"] = false
        let identity: [String: Any] = ["event_name": event.label, "hooks": [handler]]
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func key(_ path: String, _ label: String, _ group: Int) -> String { "\(path):\(label):\(group):0" }

    /// Codex 认的路径：解析符号链接后的真实路径（`/tmp` 是 `/private/tmp`）。
    static func realPath(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return (realPath(url.deletingLastPathComponent()) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private static func quoted(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `config.toml` 里这个键的 `trusted_hash`：Codex 写成 `[hooks.state."<键>"]` 一张表，下一行是 `trusted_hash = "…"`。
    static func trustedHash(of key: String, in config: String) -> String? {
        let header = "[hooks.state.\(quoted(key))]"
        var inTable = false
        for line in config.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                inTable = line == header
                continue
            }
            guard inTable, line.hasPrefix("trusted_hash"), let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end
            else { continue }
            return String(line[line.index(after: start)..<end])
        }
        return nil
    }

    /// 认 CuePad 的条目只看命令：`<…/cuepad> hook codex`（路径可能是 App 的旧位置，可能带引号）。
    static func isOurCommand(_ command: String) -> Bool {
        let suffix = " hook \(AgentKind.codex.rawValue)"
        guard command.hasSuffix(suffix) else { return false }
        let executable = command.dropLast(suffix.count).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return URL(filePath: executable).lastPathComponent == "cuepad"
    }

    private static func json(_ node: CodexJSONTree.Node, in text: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: text[node.range])) as? [String: Any]
    }

    private static func isOurs(_ node: CodexJSONTree.Node, in text: Data) -> Bool {
        ((json(node, in: text)?["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String).map(isOurCommand) ?? false }
    }

    private static func groups(of event: String, in tree: CodexJSONTree) -> [CodexJSONTree.Node] {
        tree.root.member("hooks")?.member(event)?.elements ?? []
    }

    private static func ours(in tree: CodexJSONTree) -> [CodexJSONTree.Node] {
        events.flatMap { groups(of: $0.name, in: tree) }.filter { isOurs($0, in: tree.text) }
    }

    // MARK: 就地改写 hooks.json

    /// 删掉 CuePad 的组；`dropping` 里记着的 CuePad 建的事件数组与 `hooks` 因此空了也删掉（nil：结构都留着，升级时用）。
    /// 一次删一处、重新扫描，删法是插入的逆操作。
    static func removingOurs(from text: Data, dropping footprint: Footprint?) throws -> Data {
        var text = text
        while true {
            let tree = try CodexJSONTree(text)
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
    static func appending(
        _ groups: [(event: String, group: [String: Any])], to text: Data
    ) throws -> (text: Data, createdHooks: Bool, createdEvents: [String]) {
        func encoded(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
        }
        let tree = try CodexJSONTree(text)
        guard let hooks = tree.root.member("hooks") else {
            var object: [String: Any] = [:]
            for (event, group) in groups { object[event] = [group] }
            return (tree.root.inserting(member: "\"hooks\":" + (try encoded(object)), in: text), true, groups.map(\.event))
        }
        var edits: [(at: Int, text: String)] = []
        var created: [(event: String, member: String)] = []
        for (event, group) in groups {
            if let array = hooks.member(event) {
                edits.append(array.insertion(element: try encoded(group)))
            } else {
                created.append((event, (try encoded(event)) + ":[" + (try encoded(group)) + "]"))
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

enum CodexHooksError: Error, Equatable {
    case codexNotFound
    /// hooks.json 不是 JSON 对象：不改它
    case malformed
    case notTrusted
    /// Codex 读不进 hooks.json（它的原话）
    case rejected(String)
}

extension CodexHooksError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .codexNotFound: "没有找到 codex 命令：Codex 的钩子要它来信任与撤销"
        case .malformed: "hooks.json 不是有效的 JSON，CuePad 没有改它"
        case .notTrusted: "Codex 没有信任 CuePad 的钩子（它的信任规则可能变了），钩子不会执行"
        case .rejected(let reason): "Codex 读不了 hooks.json：\(reason)"
        }
    }
}

/// JSON 原文里每个值的位置（字节区间），用来就地插入、删除而不重写整份文件。
struct CodexJSONTree {
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
