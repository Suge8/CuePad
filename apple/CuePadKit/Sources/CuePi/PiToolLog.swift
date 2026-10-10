#if os(macOS)
import CueStore
import Foundation

typealias Tools = PiChatMessage.Tools

/// 一轮里还在累计的工具活动（检查点里跨读文件带着）：调用在助手消息里，成败在后面的工具结果行里，所以调用先挂起，
/// 结果到了再落进 `PiChatMessage.Tools`（给对话里那条回答的"读了 3 个文件，改了 2 个文件"一行和点开的清单用；只记是什么，不记工具输出）；一轮结束时没等到结果的（被中止）按成功算。
struct PiToolLog: Codable, Equatable {
    private var activity = Tools()
    private var pending: [String: Call] = [:]

    struct Call: Codable, Equatable {
        var kind: Tools.Kind
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
    func summary() -> Tools? {
        var log = self
        for (_, call) in log.pending.sorted(by: { $0.key < $1.key }) { log.settle(call, failed: false) }
        return log.activity == Tools() ? nil : log.activity
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
            activity.add(call.kind)
        }
        if activity.items.count < Tools.itemLimit {
            activity.items.append(.init(kind: call.kind, target: call.target, failed: failed, added: call.added, removed: call.removed))
        }
    }
}

private extension Tools {
    mutating func add(_ kind: Kind) {
        switch kind {
        case .edit: edits += 1
        case .command: commands += 1
        case .read: reads += 1
        case .search: searches += 1
        case .other: others += 1
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
            self.init(kind: .edit, target: Self.clip(file ?? name), added: change?.added ?? written, removed: change?.removed)
        case "read":
            self.init(kind: .read, target: Self.clip(file ?? name))
        case "bash", "shell":
            let line = arguments.command?.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            self.init(kind: .command, target: Self.clip(line ?? name))
        case "grep", "find", "ls", "glob":
            self.init(kind: .search, target: Self.clip(arguments.pattern ?? file ?? name))
        default:
            self.init(kind: .other, target: Self.clip(name))
        }
    }

    static func clip(_ text: String) -> String {
        text.count <= Tools.targetLimit ? text : String(text.prefix(Tools.targetLimit - 1)) + "…"
    }

    /// 相对工作目录；工作目录之外的家目录路径写成 ~/…（完整路径不同步）。
    private static func relative(_ path: String, to cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
#endif
