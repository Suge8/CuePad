#if os(macOS)
import CuePi
import Foundation

/// gpt-live（ChatGPT 订阅、Codex 同款的内部接口）的两根线：建通话（HTTP，带上 WebRTC 的 SDP，拿回应答与通话号）与控制通道
/// （WebSocket，`wss://api.openai.com/v1/live/<通话号>`，收转写、交接、用量，发要念的话）。没有公开文档，写法照 openai/codex 的
/// codex-api `realtime_call.rs` 与 `protocol_frameless_bidi.rs`；订阅凭证走纯 WebSocket 会被拒（"Voice session access denied."），只能 WebRTC。
/// 音色只认 v3 那几种（`voice`）：给了别的（如 v2 的 marin）服务器照样回 201 和应答，但媒体会话不起，连通检查一个也不回。
enum VoiceWire {
    static let model = "gpt-live-1-codex"
    static let voice = "cove"
    private static let callURL = URL(string: "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas")!
    private static let sidebandBase = "wss://api.openai.com/v1/live/"
    /// 一条 context.append 的上限（按 UTF-8 字节，不拆字）
    private static let appendLimit = 500

    struct Call {
        let id: String
        let answer: String
        /// 建通话的回应头里带的 Codex 额度（`x-codex-primary-used-percent`，周窗口用掉的百分比），没有为 nil
        let usedPercent: Double?
    }

    enum Failure: Error, Equatable {
        /// 令牌被拒（过期或登出）：等 Codex 自己续上
        case signedOut
        /// 套餐不含语音或额度用完（403）、到了限额（429）
        case notAllowed(Int)
        case server(Int, String)
        case malformed
    }

    static func headers(_ access: CodexAccess, session: UUID) -> [String: String] {
        [
            "Authorization": "Bearer \(access.token)", "ChatGPT-Account-ID": access.accountID, "OpenAI-Alpha": "quicksilver=v2",
            "originator": "cuepad", "session-id": session.uuidString, "thread-id": session.uuidString,
        ]
    }

    static func createCall(offer: String, instructions: String, access: CodexAccess, session: UUID) async throws -> Call {
        var request = URLRequest(url: callURL)
        request.httpMethod = "POST"
        for (key, value) in headers(access, session: session) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sdp": offer,
            "session": ["model": model, "instructions": instructions, "audio": ["output": ["voice": voice]], "delegation": ["type": "client"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw Failure.signedOut
        case 403, 429: throw Failure.notAllowed(http.statusCode)
        default: throw Failure.server(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let location = http.value(forHTTPHeaderField: "Location"),
              let id = location.split(separator: "?").first?.split(separator: "/").last.map(String.init), id.hasPrefix("rtc_")
        else { throw Failure.malformed }
        return Call(id: id, answer: String(decoding: data, as: UTF8.self), usedPercent: http.value(forHTTPHeaderField: "x-codex-primary-used-percent").flatMap(Double.init))
    }

    // MARK: 控制通道

    enum Event: Equatable {
        case started
        /// 模型把用户的话交出来（`delegation.created`，target client）
        case delegation(id: String, text: String)
        /// 一轮话开始（`turn.created`）、说完（`turn.done`，带整句转写）
        case turn(assistant: Bool, done: Bool, text: String)
        /// 到此刻这次通话用掉的音频时长（`session.usage.updated`）
        case usage(audioMs: Int)
        case error(String)
    }

    enum Outgoing {
        /// 交接的回话：念给用户（channel speakable）
        case reply(delegation: String, text: String)
        /// 没有在等的交接时 Cue 说的话
        case say(String)
        case close

        var messages: [[String: Any]] {
            switch self {
            case .reply(let id, let text):
                chunks(text).map { ["type": "delegation.context.append", "delegation_item_id": id, "channel": "speakable", "content": [["type": "input_text", "text": $0]]] }
            case .say(let text):
                chunks(text).map { ["type": "session.context.append", "channel": "speakable", "content": [["type": "input_text", "text": $0]]] }
            case .close: [["type": "session.close"]]
            }
        }
    }

    static func event(_ text: String) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let type = json["type"] as? String else { return nil }
        switch type {
        case "session.started": return .started
        case "delegation.created":
            guard let item = json["item"] as? [String: Any], item["target"] as? String == "client", let id = item["id"] as? String else { return nil }
            let parts = item["content"] as? [[String: Any]] ?? []
            return .delegation(id: id, text: parts.filter { $0["type"] as? String == "input_text" }.compactMap { $0["text"] as? String }.joined())
        case "turn.created", "turn.done":
            guard let turn = json["turn"] as? [String: Any], let role = turn["role"] as? String else { return nil }
            return .turn(assistant: role == "assistant", done: type == "turn.done", text: turn["transcript"] as? String ?? "")
        case "session.usage.updated":
            return ((json["usage"] as? [String: Any])?["audio_duration_ms"] as? Int).map { .usage(audioMs: $0) }
        case "error":
            return .error(((json["error"] as? [String: Any])?["message"] as? String) ?? text)
        default: return nil
        }
    }

    static func chunks(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for character in text {
            if current.utf8.count + String(character).utf8.count > appendLimit { out.append(current); current = "" }
            current.append(character)
        }
        return current.isEmpty ? out : out + [current]
    }

    /// 接入通话的控制通道。媒体连通前服务器回 404，所以在 `VoicePeer` 报连通之后才开。收到的事件与断开都交给 `received`（断开为 nil 加原因）。
    static func sideband(call: String, access: CodexAccess, session: UUID, received: @escaping (Result<Event, SidebandClosed>) -> Void) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: sidebandBase + call)!)
        for (key, value) in headers(access, session: session) { request.setValue(value, forHTTPHeaderField: key) }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        Task {
            do {
                while true {
                    if case .string(let text) = try await task.receive(), let event = event(text) { received(.success(event)) }
                }
            } catch {
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? error.localizedDescription
                received(.failure(SidebandClosed(reason: reason, status: (task.response as? HTTPURLResponse)?.statusCode)))
            }
        }
        return task
    }

    struct SidebandClosed: Error, Equatable {
        let reason: String
        let status: Int?
    }

    static func send(_ outgoing: Outgoing, on task: URLSessionWebSocketTask) {
        for message in outgoing.messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { continue }
            task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        }
    }
}
#endif
