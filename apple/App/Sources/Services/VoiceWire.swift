#if os(macOS)
import CuePi
import Foundation

/// Codex v3 的 WebRTC 建连与单一控制连接；delegation 正文是派活入口，turn 只是转写。
/// speakable 上下文是请模型播报的输入；发送成功或追加回执都不是播放确认。
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

    static func createCall(offer: String, developer: String, access: CodexAccess, session: UUID) async throws -> Call {
        var request = URLRequest(url: callURL)
        request.httpMethod = "POST"
        for (key, value) in headers(access, session: session) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sdp": offer,
            "session": ["model": model, "audio": ["output": ["voice": voice]], "delegation": ["type": "client", "ack_filler": false],
                        "initial_items": [["type": "message", "role": "developer", "content": [["type": "input_text", "text": developer]]]]],
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

    struct Delegation: Equatable {
        let id: String
        let turn: String?
        let text: String
    }

    enum Event: Equatable {
        case started
        case turn(id: String, assistant: Bool, done: Bool, text: String)
        case delegation(Delegation)
        /// 服务器把上下文放入时间线；这个回执不表示生成了语音或播放完成。
        case context(delegation: String?, endMs: Int)
        case usage(audioMs: Int)
        case error(String)
    }

    enum Outgoing {
        /// 交接的回话：念给用户（channel speakable）
        case reply(delegation: String, text: String)
        /// 没有在等的交接时 Cue 说的话
        case say(String)

        var messages: [[String: Any]] {
            switch self {
            case .reply(let id, let text):
                chunks(text).map { ["type": "delegation.context.append", "delegation_item_id": id, "channel": "speakable", "content": [["type": "input_text", "text": $0]]] }
            case .say(let text):
                chunks(text).map { ["type": "session.context.append", "channel": "speakable", "content": [["type": "input_text", "text": $0]]] }
            }
        }
    }

    static func event(_ text: String) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let type = json["type"] as? String else { return nil }
        DebugHooks.voiceWire(text, type: type)
        switch type {
        case "session.started": return .started
        case "turn.created", "turn.done":
            guard let turn = json["turn"] as? [String: Any], let role = turn["role"] as? String, let id = turn["id"] as? String else { return nil }
            return .turn(id: id, assistant: role == "assistant", done: type == "turn.done", text: turn["transcript"] as? String ?? "")
        case "delegation.created":
            guard let item = json["item"] as? [String: Any], item["target"] as? String == "client", let id = item["id"] as? String else { return nil }
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .delegation(Delegation(id: id, turn: item["user_bidi_turn_id"] as? String, text: text))
        case "delegation.context.appended", "session.context.appended":
            return .context(delegation: json["delegation_item_id"] as? String, endMs: json["end_ms"] as? Int ?? 0)
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

    /// 每个 call 只有一个控制连接，reader 与发送都由通话拥有；关闭会取消在等的收发。
    final class Channel: VoiceControl {
        private let socket: URLSessionWebSocketTask
        private var reader: Task<Void, Never>?

        init(call: String, access: CodexAccess, session: UUID, received: @escaping (Result<Event, SidebandClosed>) -> Void) {
            var request = URLRequest(url: URL(string: sidebandBase + call)!)
            for (key, value) in headers(access, session: session) { request.setValue(value, forHTTPHeaderField: key) }
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            reader = Task {
                do {
                    while !Task.isCancelled {
                        if case .string(let text) = try await socket.receive(), let event = event(text) { received(.success(event)) }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? error.localizedDescription
                    received(.failure(SidebandClosed(reason: reason, status: (socket.response as? HTTPURLResponse)?.statusCode)))
                }
            }
        }

        func send(_ outgoing: Outgoing) async throws {
            for message in outgoing.messages {
                try Task.checkCancellation()
                let data = try JSONSerialization.data(withJSONObject: message)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            }
        }

        func close() {
            reader?.cancel()
            reader = nil
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    struct SidebandClosed: Error, Equatable {
        let reason: String
        let status: Int?
    }
}
#endif
