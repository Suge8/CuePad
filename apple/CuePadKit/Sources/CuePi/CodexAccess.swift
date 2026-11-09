#if os(macOS)
import Foundation

/// 本机 Codex 此刻的 ChatGPT 访问令牌（`AgentIntegration.codexAccess`），给要用同一个 ChatGPT 订阅的地方（实时语音）。
/// 通过 app-server 的 getAuthStatus（includeToken=true、refreshToken=false）获取；本客户端不直接读写 Codex 凭证文件，也不自行使用续期令牌。
/// refreshToken=false 不强制续期，但令牌临近过期时 Codex 自身仍可能续期并写回凭证；不是整个调用链只读、不续期的保证。
public struct CodexAccess: Sendable {
    public let token: String
    /// 令牌里的 ChatGPT 账号（请求头 `ChatGPT-Account-ID`）
    public let accountID: String
    public let expiresAt: Date
}

public enum CodexAccessError: Error, Equatable {
    case notInstalled
    /// Codex 没登录，或登的不是 ChatGPT 账号（API Key 用不了订阅的语音）
    case signedOut
}

extension AgentIntegration {
    /// 起一个一次性的 `codex app-server`（同探测，不开线程）问令牌，问完就停。
    @MainActor public func codexAccess(executable: URL?) async throws -> CodexAccess {
        guard let executable else { throw CodexAccessError.notInstalled }
        let locator = await locate()
        let rpc = try await CodexRPC.launch(executable, environment: locator.environment(launching: executable, overrides: paths.launchEnvironment(of: .codex)))
        let status = try await withStopped(rpc, stop: { await $0.shutdown() }) { try await $0.call("getAuthStatus", ["includeToken": true, "refreshToken": false]) }
        guard status["authMethod"]?.string == "chatgpt", let token = status["authToken"]?.string, let access = CodexAccess(token: token) else {
            throw CodexAccessError.signedOut
        }
        return access
    }
}

extension CodexAccess {
    /// 账号与到期从令牌（JWT）的声明里读：`https://api.openai.com/auth` 下的 `chatgpt_account_id` 与 `exp`。
    public init?(token: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String,
              let exp = claims["exp"] as? Double
        else { return nil }
        self.init(token: token, accountID: account, expiresAt: Date(timeIntervalSince1970: exp))
    }
}
#endif
