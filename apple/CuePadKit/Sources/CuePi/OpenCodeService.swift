#if os(macOS)
import CueStore
import Darwin
import Foundation

/// OpenCode 后台服务的登记文件（`AgentPaths.openCodeService`）：服务起来时写、停了删。密码明文，所以只认属于当前用户、
/// 只有属主可读写（0600）的普通文件，与 Pi 的 socket 同一条校验。
struct OpenCodeServiceInfo: Decodable, Equatable, Sendable {
    var id: String
    var version: String
    var url: URL
    var pid: Int32
    var password: String

    /// 没有登记（服务没开）为 nil；登记文件不安全、读不懂、或服务是 v1（接口不同）也当没有——这时 CuePad 不连它。
    static func read(_ file: URL) -> OpenCodeServiceInfo? {
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              let data = try? Data(contentsOf: file), let info = try? JSONDecoder().decode(Self.self, from: data),
              info.version.hasPrefix("2.") else { return nil }
        return info
    }

    /// 服务进程的启动时刻：会话在线的规则以它为界（见 `OpenCodeRuntime`）。进程已不在为 nil。
    var startedAt: Date? { PiProcess.running(pid: pid)?.startDate }
}

/// 服务接口的报错：`tag` 是它的错误类型（`SessionNotFoundError`、`CommandNotFoundError`……）。
struct OpenCodeAPIError: Error, Equatable {
    var status: Int
    var tag: String?
    var message: String
}

/// 一个 OpenCode v2 后台服务的接口（`/api/...`，Basic 认证，用户名固定 `opencode`）。公开文档写的是 v1（`/event`、`properties`），不适用。
/// 跟工作目录有关的接口（模型、命令、待答的权限与表单的全量列表）按请求头 `x-opencode-directory` 取那个目录的。
struct OpenCodeClient: Sendable {
    let service: OpenCodeServiceInfo
    private let session: URLSession
    private let authorization: String

    init(_ service: OpenCodeServiceInfo) {
        self.service = service
        let configuration = URLSessionConfiguration.ephemeral
        // 事件流每 15 秒左右有一行心跳：一分钟收不到任何东西就是服务卡住了，断开重连
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration)
        authorization = "Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString()
    }

    private func request(_ method: String, _ path: String, directory: String? = nil, body: (any Encodable)? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: service.url.absoluteString + path)!)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let directory {
            request.setValue(directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "x-opencode-directory")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    @discardableResult
    @concurrent func call(_ method: String, _ path: String, directory: String? = nil, body: (any Encodable & Sendable)? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: request(method, path, directory: directory, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { var _tag: String?; var message: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw OpenCodeAPIError(status: status, tag: failure?._tag, message: failure?.message ?? String(decoding: data, as: UTF8.self))
        }
        return data
    }

    @concurrent func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, directory: String? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await call("GET", path, directory: directory))
    }

    /// 事件流（`GET /api/event`，SSE）：连上后第一条是 `server.connected`；只给出接入用得到的事件（`isRelevant`），
    /// 解码在后台。服务不续传：断开期间的事件就丢了，重连后要重拉快照。连接断开或出错时流结束（抛错）。
    func events() -> AsyncThrowingStream<OpenCodeEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<OpenCodeEvent, any Error>.makeStream()
        let reader = Task { @concurrent in
            do {
                let (bytes, response) = try await session.bytes(for: request("GET", "/api/event"))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw OpenCodeAPIError(status: status, tag: nil, message: "事件流连不上") }
                let decoder = JSONDecoder()
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    let payload = Data(line.dropFirst(5).utf8)
                    guard let event = try? decoder.decode(OpenCodeEvent.self, from: payload), event.isRelevant else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reader.cancel() }
        return stream
    }
}

/// 事件流里的一条（`{type, location, data}`）。各类事件的字段并成一个宽结构，用到的才解。
struct OpenCodeEvent: Decodable, Sendable {
    var type: String
    /// 与工作目录有关的事件（模型、命令清单变了）在哪个目录
    var location: OpenCodeLocation?
    var data: Payload

    struct Payload: Decodable, Sendable {
        var sessionID: String?
        var parentID: String?
        var id: String?
        var title: String?
        var agent: String?
        var model: OpenCodeModelRef?
        var location: OpenCodeLocation?
        var name: String?
        var input: OpenCodeToolInput?
        var error: OpenCodeFailure?
        var tokens: OpenCodeTokens?
        var form: OpenCodeForm?
        var action: String?
        var resources: [String]?
        var requestID: String?
        var item: Item?
        /// 正文的增量（`session.text.delta`）与说完的全文（`session.text.ended`）属于哪条回答的第几段
        var assistantMessageID: String?
        var ordinal: Int?
        var delta: String?
        var text: String?

        struct Item: Decodable, Sendable { var payload: OpenCodePrompt? }
    }

    /// 接入用得到的事件：会话、执行、步骤、工具、权限、表单、压缩，以及工作目录里模型与命令清单变了。逐字增量只要正文的
    /// （`session.text.delta`，正在说的话），思考、工具参数与压缩的不要。
    var isRelevant: Bool {
        if type.hasSuffix(".delta") { return type == "session.text.delta" }
        return type == "server.connected" || type == "model.updated" || type == "command.updated"
            || type.hasPrefix("session.") || type.hasPrefix("permission.") || type.hasPrefix("form.")
    }
}

/// 事件流里各会话正在说的话（`PiDraft`）：正文的增量（`session.text.delta`）按回答（`assistantMessageID`）累积，同一条回答的几段按段号
/// （`ordinal`）排、换行连接（与对话里这条回答的写法一致，见 `OpenCodeHistory`），一段说完（`session.text.ended`）换成这段的全文；
/// 换一条回答就重来；转成工具调用（`session.tool.input.started`）、下一轮开始（`session.execution.started`）、这一轮停下或失败时清掉，
/// 正常说完的留着。服务不续传：断线重连后错过的增量补不回来，由调用方 `reset`。
struct OpenCodeDrafts {
    private struct Entry {
        var message: String
        var parts: [Int: String] = [:]
        var since: Date
        var draft: PiDraft { PiDraft(text: parts.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n"), since: since) }
    }
    private var entries: [String: Entry] = [:]

    /// 这条事件改了哪个会话正在说的话、改成什么；与正在说的话无关或没有变化为 nil。
    mutating func apply(_ event: OpenCodeEvent) -> (sessionID: String, draft: PiDraft?)? {
        let data = event.data
        guard let sessionID = data.sessionID else { return nil }
        switch event.type {
        case "session.text.delta":
            guard let message = data.assistantMessageID, let delta = data.delta else { return nil }
            var entry = entries[sessionID].flatMap { $0.message == message ? $0 : nil } ?? Entry(message: message, since: .now)
            entry.parts[data.ordinal ?? 0, default: ""] += delta
            entries[sessionID] = entry
            return (sessionID, entry.draft)
        case "session.text.ended":
            guard var entry = entries[sessionID], entry.message == data.assistantMessageID, let text = data.text,
                  entry.parts[data.ordinal ?? 0].map({ $0 != text }) == true else { return nil }
            entry.parts[data.ordinal ?? 0] = text
            entries[sessionID] = entry
            return (sessionID, entry.draft)
        case "session.tool.input.started", "session.execution.started", "session.execution.failed", "session.execution.interrupted",
             "session.deleted":
            guard entries.removeValue(forKey: sessionID) != nil else { return nil }
            return (sessionID, nil)
        default:
            return nil
        }
    }

    /// 全部清掉（断线重连），返回原先有草稿的会话。
    mutating func reset() -> [String] {
        defer { entries = [:] }
        return Array(entries.keys)
    }
}

struct OpenCodeLocation: Codable, Sendable, Equatable { var directory: String }

struct OpenCodeModelRef: Codable, Sendable, Equatable {
    var id: String
    var providerID: String
    var variant: String?
}

struct OpenCodeFailure: Decodable, Sendable {
    var type: String?
    var message: String?
}

struct OpenCodeTokens: Decodable, Sendable {
    var input: Int
    var output: Int
    var cache: Cache?
    struct Cache: Decodable, Sendable { var read: Int; var write: Int }

    /// 下一次请求要带上的上下文：这一步的输入（含缓存）加它的输出。
    var context: Int { input + output + (cache?.read ?? 0) + (cache?.write ?? 0) }
}

struct OpenCodePrompt: Decodable, Sendable {
    var text: String?
    var metadata: Metadata?
    struct Metadata: Decodable, Sendable { var cuepadDelivery: String? }
}

/// 工具调用的参数：摘要（`PiToolLog`）认的那几项；OpenCode 的替换写成 `oldString`/`newString`，换成摘要认的写法再解。
struct OpenCodeToolInput: Decodable, Sendable {
    var arguments: PiToolArguments

    private struct Replacement: Decodable {
        var path: String?
        var oldString: String?
        var newString: String?
        func recoded() throws -> Data {
            try JSONSerialization.data(withJSONObject: ["path": path ?? "", "oldText": oldString ?? "", "newText": newString ?? ""])
        }
    }

    init(from decoder: any Decoder) throws {
        let replacement = try? Replacement(from: decoder)
        if let replacement, replacement.oldString != nil || replacement.newString != nil {
            arguments = try JSONDecoder().decode(PiToolArguments.self, from: replacement.recoded())
        } else {
            arguments = try PiToolArguments(from: decoder)
        }
    }
}

/// 待答的表单（`question` 工具就是一张表单）：字段 `q0`、`q1`……
struct OpenCodeForm: Decodable, Sendable {
    var id: String
    var sessionID: String
    var title: String?
    var fields: [Field]

    struct Field: Decodable, Sendable {
        var key: String
        var type: String
        var title: String?
        var description: String?
        var options: [Option]?
    }

    struct Option: Decodable, Sendable {
        var value: String
        var label: String
    }
}

/// 待答的权限请求。
struct OpenCodePermission: Decodable, Sendable {
    var id: String
    var sessionID: String
    var action: String
    var resources: [String]
}

/// 服务里的一个会话（`GET /api/session` 的一项）。
struct OpenCodeSessionInfo: Decodable, Sendable {
    var id: String
    var parentID: String?
    var title: String?
    var agent: String?
    var model: OpenCodeModelRef?
    var location: OpenCodeLocation
    /// 最近一次执行的结果：`succeeded` / `failed` / `interrupted`
    var outcome: String?
    var time: Time

    struct Time: Decodable, Sendable {
        var created: Double
        var updated: Double
    }

    var updatedAt: Date { Date(timeIntervalSince1970: time.updated / 1000) }
    var createdAt: Date { Date(timeIntervalSince1970: time.created / 1000) }
}

/// 一页列表：`data` 加游标。
struct OpenCodePage<Item: Decodable & Sendable>: Decodable, Sendable {
    var data: [Item]
    var cursor: Cursor?
    struct Cursor: Decodable, Sendable { var next: String? }
}

struct OpenCodeData<Item: Decodable & Sendable>: Decodable, Sendable {
    var data: Item
}

/// 可选的模型（`GET /api/model`）：`variants` 是它的思考强度。
struct OpenCodeModel: Decodable, Sendable {
    var id: String
    var providerID: String
    var name: String
    var variants: [Variant]?
    var limit: Limit?

    struct Variant: Decodable, Sendable { var id: String }
    struct Limit: Decodable, Sendable { var context: Int? }

    var key: PiModelKey { PiModelKey(provider: providerID, id: id) }

    /// 强度只认 Pi 那几档的名字；没有强度可选的模型只有 `off`（与 Pi 的规则一致）。
    var thinkingLevels: [PiThinkingLevel] {
        let levels = (variants ?? []).compactMap { PiThinkingLevel(rawValue: $0.id) }
        return levels.isEmpty ? [.off] : levels
    }

    var option: PiModelOption { PiModelOption(key: key, name: name, thinkingLevels: thinkingLevels) }
}

/// 斜杠命令（`GET /api/command`）。
struct OpenCodeCommand: Decodable, Sendable {
    var name: String
    var description: String?
}
#endif
