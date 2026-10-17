import CueText
import Foundation

/// Pi 上报的模型调用错误（`error` 状态的原文）的人话摘要。Pi 只给出一段文字——常见是
/// "状态码 + 提供方的 JSON 错误体"，也可能是网络库的报错——这里提取状态码与提供方的错误类型、消息并归类。
/// `title` 是一句中文，`providerMessage` 是提供方给的原句（可作补充说明），`raw` 是完整原文（悬停显示）。
public struct PiErrorSummary: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 401/403：密钥无效、登录过期、没有权限
        case authentication
        /// 额度、余额、订阅用量用完（按消息内容识别，不论状态码：Anthropic 的用量上限与余额不足都是 400）
        case quota
        /// 429 等限流
        case rateLimited
        /// 400 等：请求被模型拒绝（内容太大、参数不合法……）
        case rejected
        /// 5xx 与过载
        case server
        /// 连不上、断开、超时（没有 HTTP 状态）
        case network
        /// 模型不存在或这个账号用不了
        case modelUnavailable
        /// 回答超出了输出长度上限
        case outputTooLong
        case other
    }

    public let kind: Kind
    public let status: Int?
    public let providerMessage: String?
    public let raw: String

    private static let firstLineLimit = 120

    public init(_ raw: String) {
        self.raw = raw
        status = Self.status(in: raw)
        let error = Self.providerError(in: raw)
        providerMessage = error.message
        kind = Self.kind(status: status, type: error.type, text: raw.lowercased())
    }

    /// 一句中文摘要。
    public var title: String {
        let code = status.map { "（\($0)）" } ?? ""
        return switch kind {
        case .authentication: "认证失败，检查 API 密钥或重新登录\(code)"
        case .quota: "额度用完"
        case .rateLimited: "请求太频繁，稍后再试"
        case .rejected: "模型拒绝了请求\(code)"
        case .server: "模型服务繁忙或出错，稍后再试\(code)"
        case .network: "网络连接中断"
        case .modelUnavailable: "模型不存在或没有权限"
        case .outputTooLong: "回答超出了输出长度上限"
        case .other: status == nil ? Self.firstLine(of: raw) : "模型调用出错\(code)"
        }
    }

    /// Agent 把这次错误也写成了一条回答（Claude Code 的 `API Error: …`、"There's an issue with the selected model…"）：
    /// `reply` 归类后就是会话出错的那句说明（`line`），或就是说明里提供方的那句原话。这时对话里已经有它，出错的原因不再另显示一处。
    public static func echoes(_ reply: String?, line: String?) -> Bool {
        guard let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty, let line else { return false }
        return PiErrorSummary(reply).line == line || line.hasSuffix("：" + reply)
    }

    /// 不能悬停看原文的地方（手机、菜单栏）用：摘要，加上提供方的原句（有的话）。
    public var line: String {
        [title, providerMessage].compactMap { $0 }.joined(separator: "：")
    }

    // MARK: 解析

    /// 开头的 `400 …` / `400: …`（Claude Code 写成 `API Error: 400 …`），或 `(400)`。
    private static func status(in raw: String) -> Int? {
        let match = raw.firstMatch(of: /^\s*(?:API Error:\s*)?(\d{3})\b/) ?? raw.firstMatch(of: /\((\d{3})\)/)
        return match.flatMap { Int($0.1) }.flatMap { (100...599).contains($0) ? $0 : nil }
    }

    /// 原文里第一个 JSON 对象的错误类型与消息：`{"error":{"type"|"code","message"}}` 或顶层的同名字段。
    private static func providerError(in raw: String) -> (type: String?, message: String?) {
        guard let start = raw.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(raw[start...].utf8)) as? [String: Any]
        else { return (nil, nil) }
        let error = object["error"] as? [String: Any] ?? object
        let type = error["type"] as? String ?? error["code"] as? String
        return (type, error["message"] as? String)
    }

    /// Claude Code 报的错误类型（StopFailure 钩子的 `error`、流里出错的那条回答的 `error`，见官方 hooks 文档）。
    private static let claudeCodes: [String: Kind] = [
        "rate_limit": .rateLimited, "overloaded": .server, "server_error": .server,
        "authentication_failed": .authentication, "oauth_org_not_allowed": .authentication, "account_on_hold": .authentication,
        "cloud_credential_error": .authentication, "billing_error": .quota, "invalid_request": .rejected,
        "model_not_found": .modelUnavailable, "max_output_tokens": .outputTooLong,
    ]

    private static func kind(status: Int?, type: String?, text: String) -> Kind {
        let type = type?.lowercased() ?? ""
        if let kind = claudeCodes[type] { return kind }
        if status == 401 || status == 403 || ["authentication_error", "permission_error"].contains(type)
            || text.contains(/invalid.?(x-)?api.?key|unauthorized/) { return .authentication }
        // 额度类的各家说法：OpenAI `insufficient_quota`、Anthropic "usage limits" / "credit balance is too low" /
        // 订阅的 "extra usage"、Codex/ChatGPT 订阅 `usage_limit_reached` / "usage limit" /
        // `subscription_sharing_usage_limit_exceeded`、OpenRouter "Insufficient credits"，
        // 网关的 "Insufficient account balance"，以及 Pi 自己判为不可重试额度上限的说法（packages/ai/src/utils/retry.ts：available balance、quota exceeded、billing、out of budget）
        if status == 402
            || text.contains(/insufficient[_ ]?(quota|credits|funds|balance)|insufficient\b.*\bbalance|current quota|quota[_ ]?exceeded|credit balance|extra usage|usage[_ ]?limit|usage_not_included|available balance|billing|out of budget/) {
            return .quota
        }
        if status == 429 || type == "rate_limit_error" || text.contains(/rate.?limit|too many requests/) { return .rateLimited }
        if status.map({ (500...599).contains($0) }) == true || type == "overloaded_error" { return .server }
        if status == 400 || type == "invalid_request_error" { return .rejected }
        if status == nil,
           text.contains(/connection (error|refused|reset|lost)|fetch failed|network.?error|econnreset|enotfound|eai_again|getaddrinfo|socket hang up|timed? ?out|terminated/) {
            return .network
        }
        return .other
    }

    /// 识别不了时：原文首行，去掉 JSON 部分，过长截断。
    private static func firstLine(of raw: String) -> String {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = (line.firstIndex(of: "{").map { String(line[..<$0]) } ?? line).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "模型调用出错" }
        return text.clipped(firstLineLimit)
    }
}
