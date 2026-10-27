#if os(macOS)
import CueStore
import Darwin
import Foundation

/// 一台 OpenCode v2 服务（接口地址、进程、密码），两种来源：
/// - 后台服务的登记文件（`AgentPaths.openCodeService`，不在官方文档里）：服务起来时写、停了删。密码明文，所以只认属于当前用户、
///   只有属主可读写（0600）的普通文件，与 Pi 的 socket 同一条校验；
/// - CuePad 自己起的 `opencode serve --stdio`（`OpenCodeClient.serve`）：标准输出的第一行是握手（`{"url": …}`），密码是起它时给的。
struct OpenCodeServiceInfo: Equatable, Sendable {
    var url: URL
    var pid: Int32
    var password: String

    /// 没有登记（服务没开）为 nil；登记文件不安全、读不懂、或服务是 v1（接口不同）也当没有——这时 CuePad 不连它。
    static func read(_ file: URL) -> OpenCodeServiceInfo? {
        struct Registration: Decodable { var version: String; var url: URL; var pid: Int32; var password: String }
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              let data = try? Data(contentsOf: file), let registration = try? JSONDecoder().decode(Registration.self, from: data),
              registration.version.hasPrefix("2.") else { return nil }
        return OpenCodeServiceInfo(url: registration.url, pid: registration.pid, password: registration.password)
    }

    /// `serve --stdio` 的握手那一行；读不懂为 nil。
    static func stdio(_ handshake: Data, pid: Int32, password: String) -> OpenCodeServiceInfo? {
        struct Handshake: Decodable { var url: URL }
        return (try? JSONDecoder().decode(Handshake.self, from: handshake)).map { OpenCodeServiceInfo(url: $0.url, pid: pid, password: password) }
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

    private static let sessionPage = 200

    /// 全部会话（`GET /api/session` 按页取完）；`filter` 是另加的查询条件（如 `&directory=…`）。
    func sessions(_ filter: String = "") async throws -> [OpenCodeSessionInfo] {
        var all: [OpenCodeSessionInfo] = []
        var cursor: String?
        repeat {
            let query = "limit=\(Self.sessionPage)" + filter + (cursor.map { "&cursor=" + Self.escaped($0) } ?? "")
            let page = try await get(OpenCodePage<OpenCodeSessionInfo>.self, "/api/session?\(query)")
            all += page.data
            cursor = page.data.isEmpty ? nil : page.cursor?.next
        } while cursor != nil
        return all
    }

    static func escaped(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value }

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
        /// 工具的结果（`session.tool.success`）：内容块
        var content: JSONValue?
        /// 正文的增量（`session.text.delta`）与说完的全文（`session.text.ended`）属于哪条回答的第几段
        var assistantMessageID: String?
        var ordinal: Int?
        var delta: String?
        var text: String?
        /// 这一步开始的时刻（ms，`session.step.started`），就是这条回答消息的建立时刻
        var started: Double?

        struct Item: Decodable, Sendable { var payload: OpenCodePrompt? }
    }

    /// 接入与大脑用得到的事件：会话、执行、步骤、工具、权限、表单、压缩，工作目录里模型与命令清单变了，MCP 服务的状态变了。
    /// 逐字增量只要正文的（`session.text.delta`，正在说的话），思考、工具参数与压缩的不要。
    var isRelevant: Bool {
        if type.hasSuffix(".delta") { return type == "session.text.delta" }
        return type == "server.connected" || type == "model.updated" || type == "command.updated" || type == "mcp.status.changed"
            || type.hasPrefix("session.") || type.hasPrefix("permission.") || type.hasPrefix("form.")
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
    var cache: Cache?
    struct Cache: Decodable, Sendable { var read: Int; var write: Int }

    /// 这一步请求模型的输入合计（上下文用量的口径，`TurnEvent.context`）：`input` 不含缓存命中与写入，加上它们。
    var prompt: Int { input + (cache?.read ?? 0) + (cache?.write ?? 0) }
}

struct OpenCodePrompt: Decodable, Sendable {
    var text: String?
    var metadata: Metadata?
    struct Metadata: Decodable, Sendable { var cuepadDelivery: String? }
}

/// 工具调用的参数：原文（`json`），与摘要（`PiToolLog`）认的那几项；OpenCode 的替换写成 `oldString`/`newString`，换成摘要认的写法再解。
struct OpenCodeToolInput: Decodable, Sendable {
    var json: JSONValue
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
        json = try JSONValue(from: decoder)
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
        /// 有选项时还能自己填
        var custom: Bool?
    }

    struct Option: Decodable, Sendable {
        var value: String
        var label: String
    }
}

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
    var metadata: Metadata?

    struct Time: Decodable, Sendable {
        var created: Double
        var updated: Double
    }

    /// `cuepadBrain`：Cue 的大脑开的会话（`OpenCodeBrain`），值是起它的那台服务的 pid
    struct Metadata: Codable, Sendable { var cuepadBrain: Int32? }

    /// Cue 的大脑开的会话：它的服务与接入连的后台服务共用用户的库，接入照这个标记跳过（不上桥、不进会话索引与历史）。
    var isCueBrain: Bool { metadata?.cuepadBrain != nil }

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

/// 可选的模型（`GET /api/model`）：`variants` 是它的思考强度，`capabilities.input` 是它收得下的输入（`text`、`image` 等）。
struct OpenCodeModel: Decodable, Sendable {
    var id: String
    var providerID: String
    var name: String
    var variants: [Variant]?
    var limit: Limit?
    var capabilities: Capabilities?

    struct Variant: Decodable, Sendable { var id: String }
    struct Limit: Decodable, Sendable { var context: Int? }
    struct Capabilities: Decodable, Sendable { var input: [String]? }

    var key: PiModelKey { PiModelKey(provider: providerID, id: id) }

    /// 强度只认 Pi 那几档的名字；没有强度可选的模型只有 `off`（与 Pi 的规则一致）。
    var thinkingLevels: [PiThinkingLevel] {
        let levels = (variants ?? []).compactMap { PiThinkingLevel(rawValue: $0.id) }
        return levels.isEmpty ? [.off] : levels
    }

    var seesImages: Bool? { capabilities?.input.map { $0.contains("image") } }

    var option: PiModelOption {
        PiModelOption(key: key, name: name, thinkingLevels: thinkingLevels, acceptsImages: seesImages)
    }

    /// 这档强度在这个模型上的写法（`variant`）：夹到它有的档，夹到 `off`（含没有强度可选的模型）就不带。
    func variant(for level: PiThinkingLevel) -> String? {
        let level = level.clamped(to: thinkingLevels)
        return level == .off ? nil : level.rawValue
    }

    func ref(_ variant: String?) -> OpenCodeModelRef { OpenCodeModelRef(id: id, providerID: providerID, variant: variant) }
}

/// MCP 服务（`GET /api/mcp`）：`status.status` 是 `connected` / `pending` / `failed` / `needs_auth` / `disabled`。
struct OpenCodeMCPServer: Decodable, Sendable {
    var name: String
    var status: Status
    struct Status: Decodable, Sendable { var status: String; var error: String? }
}

/// 斜杠命令（`GET /api/command`）。
struct OpenCodeCommand: Decodable, Sendable {
    var name: String
    var description: String?
}

enum OpenCodeAnswer: Encodable {
    case string(String), bool(Bool)
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}
#endif
