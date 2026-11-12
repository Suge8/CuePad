#if os(macOS)
import CueStore
import CueText
import Foundation

typealias Tools = ChatMessage.Tools

/// 调用在助手消息里，成败在后面的工具结果行里，所以调用先挂起，结果到了再落进 `ChatMessage.Tools`（只记是什么，不记工具输出）。一轮结束时没等到结果的（被中止）按成功算。
struct ToolLog: Codable, Equatable {
    private var activity = Tools()
    private var pending: [String: Call] = [:]

    struct Call: Codable, Equatable {
        var kind: Tools.Kind
        var target: String
        var added: Int?
        var removed: Int?
    }

    mutating func start(id: String, name: String, arguments: ToolArguments, cwd: String?) {
        let call = Call(name: name, arguments: arguments, cwd: cwd)
        // `cuepad show` 的结果就是对话里那张预览卡：清单里不再列一遍，也不算进命令数
        guard call.kind != .command || call.target.prefixMatch(of: Self.preview) == nil else { return }
        pending[id] = call
    }

    /// 发预览的命令行：`cuepad show …`，cuepad 可以带路径（技能里写的是 App 内的绝对路径，含空格时整段加单引号）。
    private static var preview: Regex<Substring> { /(?:'[^']*\/|[^\s']*\/)?cuepad'?\s+show(?:\s|$)/ }

    mutating func finish(id: String, failed: Bool, images: [String] = []) {
        guard let call = pending.removeValue(forKey: id) else { return }
        settle(call, id: id, failed: failed, images: images)
    }

    /// 一次模型请求的缓存读写：`recached` 是没接上缓存、原价重送的量（接上了为 0）。
    mutating func requested(context: Int, recached: Int, warmUntil: Date?) {
        let missed = (activity.cache?.recached ?? 0) + recached
        activity.cache = Tools.Cache(recached: missed > 0 ? missed : nil, context: context, warmUntil: warmUntil)
    }

    mutating func say(_ text: String) {
        activity.record(.init(kind: .said, target: text.clipped(Tools.saidLimit)))
    }

    var settled: Tools? { activity == Tools() ? nil : activity }

    func summary() -> Tools? {
        var log = self
        for (id, call) in log.pending.sorted(by: { $0.key < $1.key }) { log.settle(call, id: id, failed: false) }
        if let answer = log.activity.items.lastIndex(where: { $0.kind == .said }) { log.activity.items.remove(at: answer) }
        return log.activity == Tools() ? nil : log.activity
    }

    private mutating func settle(_ call: Call, id: String, failed: Bool, images: [String] = []) {
        if !failed, call.kind == .edit || call.kind == .read,
           let index = activity.items.firstIndex(where: { $0.kind == call.kind && $0.target == call.target && !$0.failed }) {
            let item = activity.items[index]
            activity.items[index].added = item.added.map { $0 + (call.added ?? 0) } ?? call.added
            activity.items[index].removed = item.removed.map { $0 + (call.removed ?? 0) } ?? call.removed
            let fresh = images.filter { !(item.images ?? []).contains($0) }
            if !fresh.isEmpty { activity.items[index].images = (item.images ?? []) + fresh }
            activity.items[index].calls = (item.calls ?? []) + [id]
            return
        }
        var item = Tools.Item(
            kind: call.kind, target: call.target, failed: failed, added: call.added, removed: call.removed, images: images.isEmpty ? nil : images)
        item.calls = [id]
        activity.record(item)
    }
}

/// 一次模型请求的用量里与缓存有关的几项，各家的键名都认（Pi：`input`、`cacheRead`、`cacheWrite`、`cacheWrite1h`；
/// Claude Code 照 Anthropic 的 `usage`）。哪一项类型不对就当没有：不能因为用量丢掉整行消息。
struct CacheUsage: Decodable {
    var read = 0
    var fresh = 0
    /// Agent 报了写进哪一档才知道（Anthropic 的 5 分钟与 1 小时）；只读没写的那次不报，沿用上一次的。
    var lifetime: TimeInterval?

    private enum Keys: String, CodingKey {
        case input, cacheRead, cacheWrite, cacheWrite1h
        case inputTokens = "input_tokens", readTokens = "cache_read_input_tokens", writeTokens = "cache_creation_input_tokens"
        case creation = "cache_creation"
    }
    private enum Tiers: String, CodingKey { case hour = "ephemeral_1h_input_tokens", minutes = "ephemeral_5m_input_tokens" }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        func int(_ key: Keys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        read = int(.cacheRead) + int(.readTokens)
        fresh = int(.input) + int(.cacheWrite) + int(.inputTokens) + int(.writeTokens)
        let tiers = try? c.nestedContainer(keyedBy: Tiers.self, forKey: .creation)
        func tier(_ key: Tiers) -> Int { (try? tiers?.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        if int(.cacheWrite1h) > 0 || tier(.hour) > 0 { lifetime = 3_600 } else if tier(.minutes) > 0 { lifetime = 300 }
    }
}

struct ToolArguments: Decodable {
    var path: String?
    var command: String?
    var pattern: String?
    var content: String?
    private var changes: [(old: String, new: String)] = []

    private enum Keys: String, CodingKey {
        case path, file_path, command, pattern, query, content, edits, oldText, newText, old_string, new_string
    }

    init() {}

    /// 参数不是对象、或任一项类型不对就当没有：摘要不能因为一个怪参数丢掉整行消息（它可能是这一轮的回答）。
    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        func string(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        struct Edit: Decodable { var oldText: String?; var newText: String? }
        path = string(.path) ?? string(.file_path)
        command = string(.command)
        pattern = string(.pattern) ?? string(.query)
        content = string(.content)
        for edit in (try? c.decodeIfPresent([Edit].self, forKey: .edits)) ?? [] { changes.append((edit.oldText ?? "", edit.newText ?? "")) }
        if let old = string(.oldText) ?? string(.old_string), let new = string(.newText) ?? string(.new_string) { changes.append((old, new)) }
    }

    /// 替换的新增、删除行数（按行比较，只改了一行里的字就是 +1 −1）。
    var lineChange: (added: Int, removed: Int)? {
        guard !changes.isEmpty else { return nil }
        return changes.reduce((0, 0)) { total, change in
            let old = Self.lines(change.old), new = Self.lines(change.new)
            let difference = new.difference(from: old)
            return (total.0 + difference.insertions.count, total.1 + difference.removals.count)
        }
    }

    static func lines(_ text: String) -> [Substring] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0).map { $0 }
    }
}

private extension ToolLog.Call {
    init(name: String, arguments: ToolArguments, cwd: String?) {
        let file = arguments.path.map { Self.relative($0, to: cwd) }
        let (kind, target): (Tools.Kind, String) = switch name.lowercased() {
        case "edit", "write", "strreplace", "str_replace", "multiedit": (.edit, file ?? name)
        case "read": (.read, file ?? name)
        case "bash", "shell":
            (.command, arguments.command?.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? name)
        case "grep", "find", "ls", "glob": (.search, arguments.pattern ?? file ?? name)
        default: (.other, name)
        }
        // 改文件带从参数算出的增删行数（整文件写入只有新增）
        let change = kind == .edit ? arguments.lineChange : nil
        let written = kind == .edit ? arguments.content.map { ToolArguments.lines($0).count } : nil
        self.init(kind: kind, target: target.clipped(Tools.targetLimit), added: change?.added ?? written, removed: change?.removed)
    }

    /// 相对工作目录；工作目录之外的家目录路径写成 ~/…（完整路径不同步）。
    private static func relative(_ path: String, to cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = UserHome.directory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
#endif
