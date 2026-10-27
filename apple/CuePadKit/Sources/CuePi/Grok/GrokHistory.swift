#if os(macOS)
import CueStore
import Foundation

/// Grok Build 的会话记录（`<GROK_HOME>/sessions/<百分号编码的工作目录>/<会话 id>/updates.jsonl`，Grok 恢复会话时读的就是它）的逐行解码。
/// 一行是一条原样的 ACP 通知（`{timestamp, method, params: {sessionId, update, _meta}}`）；连续的说话增量 Grok 写下之前已并成一行，
/// 写下要等下一条通知来（实测与源码 persistence.rs）。
/// - `user_message_chunk` 是你的话（文字与图片各一行；`hideFromScrollback` 的是 Grok 自己垫进去的，不算），一到就算这一轮开始。
///   发它的请求 id 只写在它之后的行上（`_meta.promptId`、`turn_completed` 的 `prompt_id`）：这一句先存在检查点里（`held`），
///   读到下一行再记下；CuePad 发的请求 id 是 `cuepad-<投送请求 id>`（`GrokDialect.promptMeta`）。
/// - `agent_message_chunk` 是说的一段，`tool_call`、`tool_call_update` 是工具活动；
/// - `turn_completed`（方法 `_x.ai/session/update`）结束这一轮：`cancelled` 是被停下，其余是做完（出错的原话不在记录里）。
/// 工作目录在路径里（`SessionFileFormat.cwd`）；会话名不在这个文件里，历史会话的名字退回首条消息。
enum GrokHistory {
    static let deliveryPrefix = "cuepad-"

    static func ingest(_ raw: UnsafeRawBufferPointer, _ cp: inout PiHistoryCheckpoint, _ transcript: inout PiHistory.Transcript) throws {
        cp.seq += 1
        guard let base = raw.baseAddress, !raw.isEmpty,
              let line = JSONValue.parse(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: raw.count, deallocator: .none)),
              let params = line["params"], let update = params["update"]
        else { return }
        if cp.sessionID == nil { cp.sessionID = params["sessionId"]?.string }
        let meta = params["_meta"]
        let time = meta?["agentTimestampMs"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? line["timestamp"]?.number.map { Date(timeIntervalSince1970: $0) }
        if let time { cp.lastActivity = time }
        let entry = PiHistory.Entry(id: meta?["eventId"]?.string ?? "\(cp.seq)", seq: cp.seq, at: time ?? cp.lastActivity ?? .distantPast)
        let kind = update["sessionUpdate"]?.string
        if kind == "user_message_chunk" {
            guard update["_meta"]?["hideFromScrollback"]?.bool != true else { return }
            return try hold(update["content"], entry, into: &cp, transcript: &transcript)
        }
        release(meta?["promptId"]?.string ?? update["prompt_id"]?.string, into: &cp, transcript: &transcript)
        switch kind {
        case "agent_message_chunk":
            if let text = update["content"]?["text"]?.string { cp.spoke(text, entry) }
        case "tool_call":
            guard let id = update["toolCallId"]?.string else { return }
            let name = update["_meta"]?["x.ai/tool"]?["name"]?.string ?? update["title"]?.string ?? "tool"
            let arguments = (update["rawInput"]?.data).flatMap { try? JSONDecoder().decode(PiToolArguments.self, from: $0) } ?? PiToolArguments()
            cp.toolStarted(id: id, name: name, arguments: arguments)
            settled(update, into: &cp)
        case "tool_call_update":
            settled(update, into: &cp)
        case "turn_completed":
            if update["stop_reason"]?.string == "cancelled" {
                cp.interrupted(entry, into: &transcript)
            } else {
                cp.answered("", entry, into: &transcript)
            }
        default:
            break
        }
    }

    /// 你的话的一行（文字或图片）：并进存着的那一句。第一行开始这一轮。
    private static func hold(_ content: JSONValue?, _ entry: PiHistory.Entry, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) throws {
        var said = transcript.said()
        if let held = cp.held {
            said.restore(text: held.text, stored: held.stored)
        } else {
            cp.roundStarted(at: entry.at)
        }
        switch content?["type"]?.string {
        case "text": said.text(content?["text"]?.string)
        case "image": try said.image(content?["data"]?.string.flatMap { Data(base64Encoded: $0) })
        default: break
        }
        let first = cp.held.map { PiHistory.Entry(id: $0.id, seq: $0.seq, at: $0.at) } ?? entry
        cp.held = PiHistoryCheckpoint.Held(text: said.text, stored: said.stored, id: first.id, seq: first.seq, at: first.at)
    }

    /// 存着的那一句等到了发它的请求 id（`prompt`）：照常记下。
    private static func release(_ prompt: String?, into cp: inout PiHistoryCheckpoint, transcript: inout PiHistory.Transcript) {
        guard let held = cp.held else { return }
        cp.held = nil
        var said = transcript.said()
        said.restore(text: held.text, stored: held.stored)
        let delivery = prompt.flatMap { $0.hasPrefix(deliveryPrefix) ? String($0.dropFirst(deliveryPrefix.count)) : nil }
        cp.said(said, PiHistory.Entry(id: held.id, seq: held.seq, at: held.at), deliveryID: delivery, into: &transcript)
    }

    private static func settled(_ update: JSONValue, into cp: inout PiHistoryCheckpoint) {
        guard let id = update["toolCallId"]?.string, let status = update["status"]?.string, status == "completed" || status == "failed" else { return }
        cp.toolFinished(id: id, failed: status == "failed")
    }
}
#endif
