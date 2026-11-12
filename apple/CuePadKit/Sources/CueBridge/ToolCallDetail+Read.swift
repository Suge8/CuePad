#if os(macOS)
import CueStore
import Foundation

extension ToolCallDetail {
    /// 按调用 id 在会话文件里找它的参数与结果。不按各家的行格式解：整行当 JSON 树，认三种形状——
    /// 带这个 id 与参数的对象、指着这个 id 的结果对象（Pi 的 `toolCall`/`toolCallId`、Claude Code 的 `tool_use`/`tool_use_id`），
    /// 与 Codex 做完的一项（同一个对象里带着命令与输出，或各文件的改动；改文件的一步 id 后面接着路径，`CodexHistory.changeCall`）。
    /// 文件读不了抛出；读到了却没有这次调用的命令、改动与文字输出（看了一张图、搜了一下网、别家的格式）是一份空的。
    @concurrent public static func read(file: URL, calls: [String]) async throws -> ToolCallDetail {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        var commands: [String] = [], diffs: [String] = [], outputs: [String] = []
        // 一步里的几次调用在文件里挨着：从第一次找到的地方往后找，不为每个 id 从头扫一遍（会话文件可以有几百 MB）
        var from = data.startIndex
        for call in calls {
            let (id, path) = CodexHistory.changeCall(call)
            let needle = Data("\"\(id)\"".utf8)
            // Claude Code 重写会话文件时同一条结果会留下两行：一次调用只取一份；两次调用各出一样的字是两份
            var called = false, output: String?
            func scan(from start: Data.Index) -> Data.Index? {
                let hits = lines(in: data, from: start, containing: needle)
                for line in hits {
                    guard let tree = try? JSONSerialization.jsonObject(with: line) else { continue }
                    visit(tree) { object in
                        if !called, object["id"] as? String == id {
                            if let input = (object["arguments"] ?? object["input"]) as? [String: Any] {
                                called = true
                                if let command = input["command"] as? String { commands.append(command) }
                                diffs += changes(input)
                            } else if let command = object["command"] as? [String] {
                                called = true
                                commands.append(command.last ?? "")
                                output = object["aggregated_output"] as? String ?? ""
                            } else if let path, let change = (object["changes"] as? [String: [String: Any]])?[path] {
                                called = true
                                diffs.append(change["unified_diff"] as? String ?? diff("", change["content"] as? String ?? "", deleted: change["type"] as? String == "delete"))
                                output = ""
                            }
                        } else if output == nil, (object["toolCallId"] ?? object["tool_use_id"]) as? String == id, let content = object["content"] {
                            output = text(content)
                        }
                    }
                }
                return hits.first?.startIndex
            }
            let first = scan(from: from)
            // 先发起、后做完的调用排在前一个之前：这里没找全就从头找
            if !called || output == nil, from > data.startIndex { _ = scan(from: data.startIndex) } else if let first { from = first }
            if let output, !output.isEmpty { outputs.append(output) }
        }
        return ToolCallDetail(
            command: commands.isEmpty ? nil : commands.joined(separator: "\n"), diff: diffs.isEmpty ? nil : diffs.joined(separator: "\n@@\n"),
            output: outputs.joined(separator: "\n")
        ).fitted()
    }

    private static func changes(_ input: [String: Any]) -> [String] {
        func change(_ object: [String: Any]) -> String? {
            guard let old = (object["oldText"] ?? object["old_string"]) as? String, let new = (object["newText"] ?? object["new_string"]) as? String else { return nil }
            return diff(old, new)
        }
        let edits = ([input] + (input["edits"] as? [[String: Any]] ?? [])).compactMap(change)
        if edits.isEmpty, input["path"] ?? input["file_path"] != nil, let written = input["content"] as? String { return [diff("", written)] }
        return edits
    }

    private static func diff(_ old: String, _ new: String, deleted: Bool = false) -> String {
        func rows(_ text: String, _ sign: String) -> [String] {
            text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { sign + $0 }
        }
        return (deleted ? rows(new, "-") : rows(old, "-") + rows(new, "+")).joined(separator: "\n")
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
