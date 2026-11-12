#if os(macOS)
import CueStore
import Foundation

/// 一步的里面：命令全文或改动的前后，与工具输出的末尾。不同步、不落库，点开那一步时由会话所在的 Mac 回会话文件现取——
/// 输出占会话体积的绝大部分，随对话同步的话每条回答大几倍（T3 Code、Buzz 也都是展开时才取）。
public struct ToolCallDetail: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var removed: String
        public var added: String
    }

    public var command: String?
    public var changes: [Change] = []
    public var output: String = ""
    /// 输出比 `outputLimit` 长，只留了末尾。
    public var clipped = false

    public var isEmpty: Bool { command == nil && changes.isEmpty && output.isEmpty }

    /// 输出只留末尾这么多字符：命令的结论（测试结果、报错）在最后。
    static let outputLimit = 16_000
    static let inputLimit = 8_000

    /// 按调用 id 在会话文件里找它的参数与结果。不按各家的行格式解：整行当 JSON 树，认"带这个 id 与参数的对象"和"指着这个 id 的结果对象"，
    /// Pi（`toolCall`/`toolCallId`）与 Claude Code（`tool_use`/`tool_use_id`）是同一套找法。找不到（文件没了、别家的格式）为 nil。
    public static func read(file: URL, calls: [String]) -> ToolCallDetail? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        var detail = ToolCallDetail(), outputs: [String] = []
        // 一步里的几次调用在文件里挨着：从第一次找到的地方往后找，不为每个 id 从头扫一遍（会话文件可以有几百 MB）
        var from = data.startIndex
        for call in calls {
            let needle = Data("\"\(call)\"".utf8)
            // Claude Code 重写会话文件时同一条结果会留下两行：一次调用只取一份；两次调用各出一样的字是两份
            var called = false, output: String?
            func scan(from start: Data.Index) -> Data.Index? {
                let hits = lines(in: data, from: start, containing: needle)
                for line in hits {
                    guard let tree = try? JSONSerialization.jsonObject(with: line) else { continue }
                    visit(tree) { object in
                        if !called, object["id"] as? String == call, let input = (object["arguments"] ?? object["input"]) as? [String: Any] {
                            called = true
                            detail.take(input)
                        } else if output == nil, (object["toolCallId"] ?? object["tool_use_id"]) as? String == call, let content = object["content"] {
                            output = text(content)
                        }
                    }
                }
                return hits.first?.startIndex
            }
            let first = scan(from: from)
            // 先发起、后做完的调用排在前一个之前：这里没找全就从头找
            if !called || output == nil, from > data.startIndex { _ = scan(from: data.startIndex) } else if let first { from = first }
            if let output { outputs.append(output) }
        }
        let output = outputs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        detail.clipped = output.count > outputLimit
        detail.output = String(output.suffix(outputLimit))
        return detail.isEmpty ? nil : detail
    }

    /// 截掉的地方留一个省略号：界面照原样排，看得出不是全文。
    private static func clip(_ text: String) -> String { text.count > inputLimit ? String(text.prefix(inputLimit)) + "\n…" : text }

    private mutating func take(_ input: [String: Any]) {
        if let command = input["command"] as? String { self.command = Self.clip(command) }
        func change(_ object: [String: Any]) {
            guard let old = (object["oldText"] ?? object["old_string"]) as? String, let new = (object["newText"] ?? object["new_string"]) as? String else { return }
            changes.append(Change(removed: Self.clip(old), added: Self.clip(new)))
        }
        change(input)
        for edit in input["edits"] as? [[String: Any]] ?? [] { change(edit) }
        if changes.isEmpty, input["path"] ?? input["file_path"] != nil, let written = input["content"] as? String {
            changes.append(Change(removed: "", added: Self.clip(written)))
        }
    }

    private static func text(_ content: Any) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func visit(_ node: Any, _ found: ([String: Any]) -> Void) {
        if let object = node as? [String: Any] {
            found(object)
            for child in object.values { visit(child, found) }
        } else if let list = node as? [Any] {
            for child in list { visit(child, found) }
        }
    }

    private static func lines(in data: Data, from start: Data.Index, containing needle: Data) -> [Data] {
        var found: [Data] = [], from = start
        while let hit = data.range(of: needle, in: from..<data.endIndex) {
            let start = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let end = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            found.append(data[start..<end])
            from = end
        }
        return found
    }
}
#endif
