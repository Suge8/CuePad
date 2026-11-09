#if os(macOS)
import CueStore
import CueText
import Foundation

/// `final_answer` 是最后一段，结束这一轮：Codex 先报歇下、钩子返回后才写 `task_complete`，等它的话歇下时对话里还没有回答；没有回答就结束的轮由 `task_complete` 结束。
/// `ImageView` 的条目只带路径（view_image 看的那个本机文件），读的时候从文件取。`response_item` 里同一条你的话没有 `client_id`，不读。
enum CodexHistory {
    /// CuePad 发出的话写进 `clientUserMessageId` 的前缀，后接投送请求的 UUID：终端里打的话 Codex 也给一个随机 UUID，靠前缀分开。
    static let clientIDPrefix = "cuepad-"

    static func clientID(for deliveryID: String?) -> String {
        deliveryID.map { clientIDPrefix + $0 } ?? UUID().uuidString
    }

    /// 全部会话共用一个：Codex 改名（`/rename`、`thread/name/set`）与终端界面自动起名都追加一行 `{id, thread_name}`，同一会话最后一行为准。
    static let sidecar = SessionFileFormat.Sidecar(file: { file in
        var home = file
        for _ in 0..<5 { home.deleteLastPathComponent() }
        return home.appending(path: indexFile)
    }, name: name)

    private static func name(in data: Data, sessionID: String) -> String? {
        let id = Data(sessionID.utf8)
        return data.split(separator: 0x0A).last { $0.firstRange(of: id) != nil }
            .flatMap { try? decoder.decode(IndexEntry.self, from: Data($0)) }.flatMap { $0.id == sessionID ? $0.threadName : nil }
    }

    private static let indexFile = "session_index.jsonl"

    private struct IndexEntry: Decodable {
        var id: String
        var threadName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }

    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq += 1
        guard let data = raw.borrowedData, let line = try? decoder.decode(Line.self, from: data)
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
            // 用技能说的（技能条目在前、话在后，`CodexRuntime.input`）写回你发的样子：`/skill:名字 话`，同 Pi 的 `PiSkillCall.line`
            var skill = item.content?.first { $0.type == "skill" }?.name.map { "/skill:\($0)" }
            for input in item.content ?? [] {
                switch input.type {
                case "text":
                    said.text([skill, input.text].compactMap(\.self).joined(separator: " "))
                    skill = nil
                case "image": try said.image(input.imageURL.flatMap(ToolImage.data(at:)))
                default: break
                }
            }
            if let skill { said.text(skill) }
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
                if item.status == "declined" {
                    cp.toolDeclined(id: call.id)
                } else {
                    cp.toolFinished(id: call.id, failed: call.failed, images: try transcript.toolImages(call.images))
                }
            }
        }
    }

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: PiToolArguments
        var failed: Bool
        var images: [Data?] = []
    }

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
            return [ToolCall(
                id: id, name: item.tool ?? "mcp", arguments: PiToolArguments(), failed: item.status.map { $0 != "completed" } ?? false,
                images: item.result?.images ?? [])]
        case "ImageView":
            var arguments = PiToolArguments()
            arguments.path = item.path.flatMap { URL(string: $0)?.path }
            return [ToolCall(id: id, name: "read", arguments: arguments, failed: false, images: [item.path.flatMap(ToolImage.data(at:))])]
        case "WebSearch":
            var arguments = PiToolArguments()
            arguments.pattern = item.query
            return [ToolCall(id: id, name: "grep", arguments: arguments, failed: false)]
        default:
            return []
        }
    }

    /// 终端里的 Plan 模式归终端界面管，app-server 不报，只有会话文件里有。
    struct LastTurn {
        var plan: Bool
        var interrupted: Bool
        /// 会话文件里已有这一轮的结束记录（`task_complete`、`turn_aborted`）；出错的一轮，`failure` 是记录里的错误原文
        var finished: Bool
        var failure: String?
    }

    /// 一行可能很长（带图的工具结果），所以从文件尾往前一块一块读；读不了或没有为 nil。
    @concurrent static func lastTurn(in file: URL) async -> LastTurn? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let block: UInt64 = 64 * 1024
        guard var end = try? handle.seekToEnd() else { return nil }
        var head = Data()
        var ended: Bool?
        var failure: String?
        while end > 0 {
            let start = end > block ? end - block : 0
            guard (try? handle.seek(toOffset: start)) != nil, let chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
            var lines = (chunk + head).split(separator: 0x0A)
            head = start > 0 && !lines.isEmpty ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() {
                guard line.firstRange(of: Data("task_".utf8)) != nil || line.firstRange(of: Data("turn_aborted".utf8)) != nil,
                      let event = try? decoder.decode(Lifecycle.self, from: Data(line)), event.type == "event_msg" else { continue }
                switch event.payload.type {
                case "task_started": return LastTurn(plan: event.payload.mode == "plan", interrupted: ended ?? false, finished: ended != nil, failure: failure)
                case "task_complete":
                    if ended == nil { failure = event.payload.error?.message }
                    ended = ended ?? false
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
            var error: Failure?

            struct Failure: Decodable {
                var message: String?
            }

            private enum CodingKeys: String, CodingKey {
                case type, reason, error
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
        var phase: String?
        var path: String?
        var result: ToolResult?

        private enum CodingKeys: String, CodingKey {
            case type, id, content, command, status, changes, tool, query, phase, path, result
            case clientID = "client_id"
            case exitCode = "exit_code"
        }
    }

    private struct Content: Decodable {
        var type: String
        var text: String?
        var imageURL: String?
        var name: String?

        private enum CodingKeys: String, CodingKey {
            case type, text, name
            case imageURL = "image_url"
        }
    }

    /// 形状不认得时当没有，不连累整条。
    private struct ToolResult: Decodable {
        var images: [Data?] = []

        private struct Block: Decodable {
            var type: String?
            var data: String?
        }

        private enum CodingKeys: String, CodingKey { case content }

        init(from decoder: any Decoder) throws {
            let blocks = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Block].self, forKey: .content)) ?? []
            images = blocks.filter { $0.type == "image" }.map { $0.data.flatMap { Data(base64Encoded: $0) } }
        }
    }

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
