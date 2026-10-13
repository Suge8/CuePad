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
        case ("event_msg", "task_started"):
            cp.round = .init(startedAt: at)
        case ("event_msg", "turn_aborted"):
            guard cp.round != nil else { return }
            cp.recap = PiRecap(lastPrompt: cp.recap.pendingPrompt ?? cp.recap.lastPrompt, lastReply: nil, pendingPrompt: nil)
            cp.round = nil
        case ("event_msg", "task_complete"):
            // 回答已在 final_answer 那条收下；没有回答的（只压缩了上下文）只结束这一轮
            cp.round = nil
        case ("event_msg", "item_completed"):
            guard let item = line.payload.item else { return }
            try completed(item, entry: (item.id ?? "\(cp.seq)", cp.seq, at), into: &cp, transcript: &transcript)
        default:
            break
        }
    }

    private typealias Entry = (id: String, seq: Int64, at: Date)

    private static func completed(_ item: Item, entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        switch item.type {
        case "UserMessage":
            try userMessage(item, entry, into: &cp, transcript: &transcript)
        case "AgentMessage" where item.phase == "final_answer":
            let text = (item.content ?? []).compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let round = cp.round ?? .init(startedAt: nil)
            if !text.isEmpty {
                transcript.add(
                    cp, entryID: entry.id, seq: entry.seq, role: .pi, text: text, at: entry.at, tools: round.tools.summary(),
                    roundStartedAt: round.startedAt)
            }
            cp.recap = PiRecap(
                lastPrompt: cp.recap.pendingPrompt ?? cp.recap.lastPrompt, lastReply: PiHistory.clip(text, PiRecap.replyLimit), pendingPrompt: nil)
            cp.round = nil
        case "ContextCompaction":
            transcript.add(cp, entryID: entry.id, seq: entry.seq, role: .system, text: "已压缩上下文", at: entry.at)
        default:
            // 工具活动只算进还没做完的那一轮（后台命令可能在这一轮结束之后才落定）
            guard cp.round != nil else { return }
            for call in toolCalls(item) {
                cp.round?.tools.start(id: call.id, name: call.name, arguments: call.arguments, cwd: cp.cwd)
                cp.round?.tools.finish(id: call.id, failed: call.failed)
            }
        }
    }

    /// 你说的一句：进对话、成为进行中的提问。整条只由 `<名字>…</名字>` 块组成的是机器消息（如子代理的通知），只开始一轮。
    private static func userMessage(_ item: Item, _ entry: Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        if cp.round == nil { cp.round = .init(startedAt: entry.at) }
        var texts: [String] = [], pieces: [String] = []
        for input in item.content ?? [] {
            switch input.type {
            case "text":
                guard let text = input.text, !text.isEmpty else { continue }
                texts.append(text)
                pieces.append(text)
            case "image":
                guard let files = transcript.files, let data = input.imageURL.flatMap(imageData) else { continue }
                do { pieces.append(CueFormat.imageMarkup(id: try files.store(data))) } catch CueStoreError.notAnImage { continue }
            default:
                break
            }
        }
        let text = texts.joined(separator: "\n")
        guard !PiHistory.isMachineMessage(text) else { return }
        if cp.firstMessage == nil, !text.isEmpty {
            cp.firstMessage = String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(PiSessionName.firstMessageLimit))
        }
        let delivery = item.clientID.flatMap { $0.hasPrefix(clientIDPrefix) ? String($0.dropFirst(clientIDPrefix.count)) : nil }
        transcript.add(
            cp, entryID: entry.id, seq: entry.seq, role: .user, text: transcript.files == nil ? text : pieces.joined(separator: "\n"), at: entry.at,
            deliveryID: delivery)
        cp.recap.pendingPrompt = PiHistory.clip(PiHistory.collapsed(text), PiRecap.promptLimit)
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
        var item: Item?
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
