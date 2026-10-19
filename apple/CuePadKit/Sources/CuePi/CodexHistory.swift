#if os(macOS)
import CueStore
import CueText
import Foundation

/// Codex 会话文件（`<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<时间>-<会话 id>.jsonl`）的逐行解码。
///
/// 一行是 `{timestamp, type, payload}`。只认 `session_meta`（会话 id、工作目录）与 `event_msg`：
/// `task_started` 开始一轮；`item_completed` 里 `UserMessage` 是你的话（`client_id` 是 CuePad 发的那条的投送请求，见 `clientID`）、
/// `AgentMessage` 是说的一段（中途的 `commentary`；`final_answer` 是最后一段，结束这一轮：Codex 先报歇下、钩子返回后才写 `task_complete`，
/// 等它的话歇下时对话里还没有回答；没有回答就结束的轮由 `task_complete` 结束）、`CommandExecution`/`FileChange`/`McpToolCall`/`WebSearch` 记工具活动、
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
            cp.interrupted(PiHistory.Entry(id: "aborted-\(cp.seq)", seq: cp.seq, at: at), into: &transcript)
        case ("event_msg", "task_complete"):
            cp.answered("", PiHistory.Entry(id: "complete-\(cp.seq)", seq: cp.seq, at: at), into: &transcript)
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
        case "AgentMessage":
            let text = (item.content ?? []).compactMap(\.text).joined(separator: "\n")
            if item.phase == "final_answer" { cp.answered(text, entry, into: &transcript) } else { cp.spoke(text, entry) }
        case "ContextCompaction":
            cp.compacted(entry, into: &transcript)
        default:
            // 工具活动只算进还没做完的那一轮（后台命令可能在这一轮结束之后才落定）
            guard cp.round != nil else { return }
            for call in toolCalls(item) {
                cp.toolStarted(id: call.id, name: call.name, arguments: call.arguments)
                if item.status == "declined" { cp.toolDeclined(id: call.id) } else { cp.toolFinished(id: call.id, failed: call.failed) }
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

    /// 会话文件里最后一轮的样子：在不在 Plan 模式（`task_started` 的 `collaboration_mode_kind`）、是不是被停下的
    /// （`turn_aborted` 的 `reason` 为 interrupted）。终端里的 Plan 模式归终端界面管，app-server 不报，只有会话文件里有。
    struct LastTurn {
        var plan: Bool
        var interrupted: Bool
    }

    /// 从文件尾往前一块一块读到最后一个 `task_started`（一行可能很长：带图的工具结果）；读不了或没有为 nil。
    @concurrent static func lastTurn(in file: URL) async -> LastTurn? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let block: UInt64 = 64 * 1024
        guard var end = try? handle.seekToEnd() else { return nil }
        var head = Data()
        var ended: Bool?
        while end > 0 {
            let start = end > block ? end - block : 0
            guard (try? handle.seek(toOffset: start)) != nil, let chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
            var lines = (chunk + head).split(separator: 0x0A)
            // 这一块的第一行可能不完整：留着拼上前一块
            head = start > 0 && !lines.isEmpty ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() {
                guard line.firstRange(of: Data("task_".utf8)) != nil || line.firstRange(of: Data("turn_aborted".utf8)) != nil,
                      let event = try? decoder.decode(Lifecycle.self, from: Data(line)), event.type == "event_msg" else { continue }
                switch event.payload.type {
                case "task_started": return LastTurn(plan: event.payload.mode == "plan", interrupted: ended ?? false)
                case "task_complete": ended = ended ?? false
                case "turn_aborted": ended = ended ?? (event.payload.reason == "interrupted")
                default: break
                }
            }
            end = start
        }
        return nil
    }

    private struct Lifecycle: Decodable {
        var type: String
        var payload: Payload

        struct Payload: Decodable {
            var type: String?
            var reason: String?
            var mode: String?

            private enum CodingKeys: String, CodingKey {
                case type, reason
                case mode = "collaboration_mode_kind"
            }
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
        var command: [String]?
        var status: String?
        var exitCode: Int?
        var changes: [String: Change]?
        var tool: String?
        var query: String?
        /// `AgentMessage`：`commentary` / `final_answer`
        var phase: String?

        private enum CodingKeys: String, CodingKey {
            case type, id, content, command, status, changes, tool, query, phase
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
