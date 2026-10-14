#if os(macOS)
import CueStore
import CueText
import Foundation

/// Codex 会话文件（`<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<时间>-<会话 id>.jsonl`）的逐行解码。
///
/// 一行是 `{timestamp, type, payload}`。只认 `session_meta`（会话 id、工作目录）与 `event_msg`：
/// `task_started` 开始一轮；`item_completed` 里 `UserMessage` 是你的话（`client_id` 是 CuePad 发的那条的投送请求，见 `clientID`）、
/// `AgentMessage` 且 `phase == final_answer` 是这一轮的回答、`CommandExecution`/`FileChange`/`McpToolCall`/`WebSearch` 记工具活动、
/// `ContextCompaction` 是压缩；`turn_aborted` 是这一轮被停下（没有回答）。`response_item` 里同一条你的话没有 `client_id`，不读。
/// 会话名只在 `<CODEX_HOME>/session_index.jsonl` 里，会话文件没有：历史会话的名字退回首条消息。
enum CodexHistory {
    /// CuePad 发出的话写进 `clientUserMessageId` 的前缀，后接投送请求的 UUID：终端里打的话 Codex 也给一个随机 UUID，靠前缀分开。
    static let clientIDPrefix = "cuepad-"

    static func clientID(for deliveryID: String?) -> String {
        deliveryID.map { clientIDPrefix + $0 } ?? UUID().uuidString
    }

    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq += 1
        guard let base = raw.baseAddress, !raw.isEmpty,
              let line = try? decoder.decode(Line.self, from: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: raw.count, deallocator: .none))
        else { return }
        let time = line.timestamp.flatMap { try? Date($0, strategy: timestampStyle) }
        if let time { cp.lastActivity = time }
        let at = time ?? cp.lastActivity ?? .distantPast
        switch (line.type, line.payload.type) {
        case ("session_meta", _):
            cp.sessionID = line.payload.id
            cp.cwd = line.payload.cwd
            // 子代理自己的会话文件与主会话同层，它的过程在主会话的子代理里看
            if line.payload.parentThreadID != nil { cp.excluded = true }
        case ("event_msg", "task_started"):
            cp.roundStarted(at: at)
        case ("event_msg", "turn_aborted"):
            cp.interrupted()
        case ("event_msg", "task_complete"):
            // 回答已在 final_answer 那条收下；没有回答的（只压缩了上下文）只结束这一轮
            cp.round = nil
        case ("event_msg", "item_completed"):
            guard let item = line.payload.item else { return }
            try completed(item, PiHistory.Entry(id: item.id ?? "\(cp.seq)", seq: cp.seq, at: at), into: &cp, transcript: &transcript)
        default:
            break
        }
    }

    private static func completed(_ item: Item, _ entry: PiHistory.Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        switch item.type {
        case "UserMessage":
            var said = transcript.said()
            for input in item.content ?? [] {
                switch input.type {
                case "text": said.text(input.text)
                case "image": try said.image(input.imageURL.flatMap(imageData))
                default: break
                }
            }
            let delivery = item.clientID.flatMap { $0.hasPrefix(clientIDPrefix) ? String($0.dropFirst(clientIDPrefix.count)) : nil }
            cp.said(said, entry, deliveryID: delivery, into: &transcript)
        case "AgentMessage" where item.phase == "final_answer":
            cp.answered((item.content ?? []).compactMap(\.text).joined(separator: "\n"), entry, into: &transcript)
        case "ContextCompaction":
            cp.compacted(entry, into: &transcript)
        default:
            // 工具活动只算进还没做完的那一轮（后台命令可能在这一轮结束之后才落定）
            guard cp.round != nil else { return }
            for call in toolCalls(item) {
                cp.toolStarted(id: call.id, name: call.name, arguments: call.arguments)
                cp.toolFinished(id: call.id, failed: call.failed)
            }
        }
    }

    /// `data:<类型>;base64,<数据>`；别的地址（网络图片）不存。
    private static func imageData(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: PiToolArguments
        var failed: Bool
    }

    /// 一个完成的工具条目换成工具活动：命令按命令行、改文件按每个文件（新增、删除行数从补丁里数）、其余按工具名。
    private static func toolCalls(_ item: Item) -> [ToolCall] {
        let id = item.id ?? UUID().uuidString
        switch item.type {
        case "CommandExecution":
            var arguments = PiToolArguments()
            arguments.command = item.command?.last
            return [ToolCall(id: id, name: "bash", arguments: arguments, failed: item.status != "completed" || (item.exitCode ?? 0) != 0)]
        case "FileChange":
            let failed = item.status.map { $0 != "completed" } ?? false
            return (item.changes ?? [:]).sorted { $0.key < $1.key }.map { path, change in
                ToolCall(id: id + path, name: "edit", arguments: change.arguments(path: path), failed: failed)
            }
        case "McpToolCall":
            return [ToolCall(id: id, name: item.tool ?? "mcp", arguments: PiToolArguments(), failed: item.status.map { $0 != "completed" } ?? false)]
        case "WebSearch":
            var arguments = PiToolArguments()
            arguments.pattern = item.query
            return [ToolCall(id: id, name: "grep", arguments: arguments, failed: false)]
        default:
            return []
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let decoder = JSONDecoder()

    private struct Line: Decodable {
        var timestamp: String?
        var type: String
        var payload: Payload
    }

    private struct Payload: Decodable {
        var type: String?
        var id: String?
        var cwd: String?
        var parentThreadID: String?
        var item: Item?

        private enum CodingKeys: String, CodingKey {
            case type, id, cwd, item
            case parentThreadID = "parent_thread_id"
        }
    }

    private struct Item: Decodable {
        var type: String
        var id: String?
        var clientID: String?
        var content: [Content]?
        var phase: String?
        var command: [String]?
        var status: String?
        var exitCode: Int?
        var changes: [String: Change]?
        var tool: String?
        var query: String?

        private enum CodingKeys: String, CodingKey {
            case type, id, content, phase, command, status, changes, tool, query
            case clientID = "client_id"
            case exitCode = "exit_code"
        }
    }

    private struct Content: Decodable {
        var type: String
        var text: String?
        var imageURL: String?

        private enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    /// 一个文件的改动：新建、删除带全文，修改带统一格式的补丁。
    private struct Change: Decodable {
        var type: String?
        var content: String?
        var unifiedDiff: String?

        private enum CodingKeys: String, CodingKey {
            case type, content
            case unifiedDiff = "unified_diff"
        }

        /// 摘要只要路径与行数：删掉的与加上的行分别当作新旧两段交给 `PiToolArguments`，按行比较得出同样的数。
        func arguments(path: String) -> PiToolArguments {
            var object: [String: String] = ["path": path]
            switch type {
            case "add":
                object["content"] = content ?? ""
            case "delete":
                (object["oldText"], object["newText"]) = (content ?? "", "")
            default:
                let lines = (unifiedDiff ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("+++") && !$0.hasPrefix("---") }
                object["oldText"] = lines.filter { $0.hasPrefix("-") }.map { $0.dropFirst() }.joined(separator: "\n")
                object["newText"] = lines.filter { $0.hasPrefix("+") }.map { $0.dropFirst() }.joined(separator: "\n")
            }
            return (try? JSONEncoder().encode(object)).flatMap { try? JSONDecoder().decode(PiToolArguments.self, from: $0) } ?? PiToolArguments()
        }
    }
}
#endif
