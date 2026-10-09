#if os(macOS)
import Foundation

/// 一轮里 Agent 的工具活动，给对话里那条回答的"读了 3 个文件，改了 2 个文件"一行和点开的清单用：
/// 分类计数（失败的不算进各类，单独计）加一份紧凑清单。只记是什么，不记工具输出；上限在这里定，Store 与同步原样带着。
public struct PiToolActivity: Sendable, Codable, Equatable {
    /// 声明顺序即摘要里的优先级：改文件、跑命令比读取和搜索更值得说。
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case edit, command, read, search, other
    }

    public struct Item: Sendable, Codable, Equatable {
        public var kind: Kind
        /// 文件路径（相对工作目录）、命令的第一个非空行、搜索的模式或工具名，至多 `targetLimit` 个字符
        public var target: String
        public var failed: Bool
        /// 改文件：从参数算出的新增、删除行数；算不出（读取、命令，或整文件写入不知道原有多少行）为 nil
        public var added: Int?
        public var removed: Int?
    }

    /// 各类成功的次数；读、改文件按文件算（同一个文件读两次、改两次只算一个）
    public var edits = 0, commands = 0, reads = 0, searches = 0, others = 0
    /// 失败的调用数
    public var failed = 0
    /// 清单，按发生先后，至多 `itemLimit` 条；超出的只进计数
    public var items: [Item] = []

    public static let itemLimit = 30
    public static let targetLimit = 120

    public subscript(kind: Kind) -> Int {
        get {
            switch kind {
            case .edit: edits
            case .command: commands
            case .read: reads
            case .search: searches
            case .other: others
            }
        }
        set {
            switch kind {
            case .edit: edits = newValue
            case .command: commands = newValue
            case .read: reads = newValue
            case .search: searches = newValue
            case .other: others = newValue
            }
        }
    }

    static func clip(_ text: String) -> String {
        text.count <= targetLimit ? text : String(text.prefix(targetLimit - 1)) + "…"
    }
}

/// 一轮里还在累计的工具活动（检查点里跨读文件带着）：调用在助手消息里，成败在后面的工具结果行里，所以调用先挂起，
/// 结果到了再落进 `PiToolActivity`；一轮结束时没等到结果的（被中止）按成功算。
struct PiToolLog: Codable, Equatable {
    private var activity = PiToolActivity()
    private var pending: [String: Call] = [:]

    struct Call: Codable, Equatable {
        var kind: PiToolActivity.Kind
        var target: String
        var added: Int?
        var removed: Int?
    }

    mutating func start(id: String, name: String, arguments: PiToolArguments, cwd: String?) {
        pending[id] = Call(name: name, arguments: arguments, cwd: cwd)
    }

    mutating func finish(id: String, failed: Bool) {
        guard let call = pending.removeValue(forKey: id) else { return }
        settle(call, failed: failed)
    }

    /// 这一轮的活动；一次工具都没调为 nil。
    func summary() -> PiToolActivity? {
        var log = self
        for (_, call) in log.pending.sorted(by: { $0.key < $1.key }) { log.settle(call, failed: false) }
        return log.activity == PiToolActivity() ? nil : log.activity
    }

    private mutating func settle(_ call: Call, failed: Bool) {
        if failed {
            activity.failed += 1
        } else if call.kind == .edit || call.kind == .read,
                  let index = activity.items.firstIndex(where: { $0.kind == call.kind && $0.target == call.target && !$0.failed }) {
            let item = activity.items[index]
            activity.items[index].added = item.added.map { $0 + (call.added ?? 0) } ?? call.added
            activity.items[index].removed = item.removed.map { $0 + (call.removed ?? 0) } ?? call.removed
            return
        } else {
            activity[call.kind] += 1
        }
        if activity.items.count < PiToolActivity.itemLimit {
            activity.items.append(.init(kind: call.kind, target: call.target, failed: failed, added: call.added, removed: call.removed))
        }
    }
}

/// 工具调用参数里摘要要用的几项；Pi 自带工具和常见别名的写法都认，别的字段不读。
struct PiToolArguments: Decodable {
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

private extension PiToolLog.Call {
    /// Pi 自带的 read / edit / write / bash / grep / find / ls，加别的提供方里同类工具的常见名字。
    init(name: String, arguments: PiToolArguments, cwd: String?) {
        let file = arguments.path.map { Self.relative($0, to: cwd) }
        switch name.lowercased() {
        case "edit", "write", "strreplace", "str_replace", "multiedit":
            let change = arguments.lineChange
            let written = arguments.content.map { PiToolArguments.lines($0).count }
            self.init(kind: .edit, target: PiToolActivity.clip(file ?? name), added: change?.added ?? written, removed: change?.removed)
        case "read":
            self.init(kind: .read, target: PiToolActivity.clip(file ?? name))
        case "bash", "shell":
            let line = arguments.command?.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            self.init(kind: .command, target: PiToolActivity.clip(line ?? name))
        case "grep", "find", "ls", "glob":
            self.init(kind: .search, target: PiToolActivity.clip(arguments.pattern ?? file ?? name))
        default:
            self.init(kind: .other, target: PiToolActivity.clip(name))
        }
    }

    /// 相对工作目录；工作目录之外的家目录路径写成 ~/…（完整路径不同步）。
    private static func relative(_ path: String, to cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
#endif
