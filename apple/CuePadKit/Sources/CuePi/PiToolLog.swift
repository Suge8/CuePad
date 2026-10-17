#if os(macOS)
import CueStore
import CueText
import Foundation

typealias Tools = PiChatMessage.Tools

/// 一轮里还在累计的经过（检查点里跨读文件带着）：调用在助手消息里，成败在后面的工具结果行里，所以调用先挂起，
/// 结果到了再落进 `PiChatMessage.Tools`（只记是什么，不记工具输出）；助手说的每段话说出时就落进去。一轮结束时没等到结果的（被中止）按成功算，
/// 最后那段话是回答，从经过里拿掉。
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
        let call = Call(name: name, arguments: arguments, cwd: cwd)
        // `cuepad show` 的结果就是对话里那张预览卡：清单里不再列一遍，也不算进命令数
        guard call.kind != .command || call.target.prefixMatch(of: Self.preview) == nil else { return }
        pending[id] = call
    }

    /// 发预览的命令行：`cuepad show …`，cuepad 可以带路径（技能里写的是 App 内的绝对路径，含空格时整段加单引号）。
    private static var preview: Regex<Substring> { /(?:'[^']*\/|[^\s']*\/)?cuepad'?\s+show(?:\s|$)/ }

    mutating func finish(id: String, failed: Bool) {
        guard let call = pending.removeValue(forKey: id) else { return }
        settle(call, failed: failed)
    }

    /// 助手说了一段话（空白的不来）。
    mutating func say(_ text: String) {
        activity.record(.init(kind: .said, target: text.clipped(Tools.saidLimit)))
    }

    /// 到目前为止做完的调用与说过的话（还在跑的调用不算）；什么都还没有为 nil。进行中这一轮的实时清单读它（`PiRecap.pendingTools`）。
    var settled: Tools? { activity == Tools() ? nil : activity }

    /// 这一轮做完时的经过：最后那段话是回答，不在经过里；什么都没有为 nil。
    func summary() -> Tools? {
        var log = self
        for (_, call) in log.pending.sorted(by: { $0.key < $1.key }) { log.settle(call, failed: false) }
        if let answer = log.activity.items.lastIndex(where: { $0.kind == .said }) { log.activity.items.remove(at: answer) }
        return log.activity == Tools() ? nil : log.activity
    }

    /// 失败的调用与成功的一样计数、各占清单里一行（只是行上标着失败）；同一个文件成功地读或改多次合成一行、只算一次。
    private mutating func settle(_ call: Call, failed: Bool) {
        if !failed, call.kind == .edit || call.kind == .read,
           let index = activity.items.firstIndex(where: { $0.kind == call.kind && $0.target == call.target && !$0.failed }) {
            let item = activity.items[index]
            activity.items[index].added = item.added.map { $0 + (call.added ?? 0) } ?? call.added
            activity.items[index].removed = item.removed.map { $0 + (call.removed ?? 0) } ?? call.removed
            return
        }
        activity.record(.init(kind: call.kind, target: call.target, failed: failed, added: call.added, removed: call.removed))
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
        let written = kind == .edit ? arguments.content.map { PiToolArguments.lines($0).count } : nil
        self.init(kind: kind, target: target.clipped(Tools.targetLimit), added: change?.added ?? written, removed: change?.removed)
    }

    /// 相对工作目录；工作目录之外的家目录路径写成 ~/…（完整路径不同步）。
    private static func relative(_ path: String, to cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
#endif
