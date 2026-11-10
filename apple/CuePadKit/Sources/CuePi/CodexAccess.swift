#if os(macOS)
import Foundation

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
    /// `AgentTimeouts.probe` 内没给出登录：起不来或不回话，例如卡在 macOS 等人确认的"是否打开"提示上（实测一卡就是一个多小时）
    case unresponsive
}

extension AgentIntegration {
    /// 至多 `AgentTimeouts.probe`（比通话的接通期限短，失败原因才轮得到它说）。开始、拿到、失败各记一行：只记阶段、用时与错误种类，不记令牌。
    @MainActor public func codexAccess(executable: URL?) async throws -> CodexAccess {
        guard let executable else { throw CodexAccessError.notInstalled }
        let started = ContinuousClock.now
        CodexRuntime.log.notice("Codex credentials: start")
        do {
            let access = try await withDeadline(AgentTimeouts.probe, orThrow: CodexAccessError.unresponsive) { @MainActor in
                let locator = await locate()
                let rpc = try await CodexRPC.launch(executable, environment: locator.environment(launching: executable, overrides: paths.launchEnvironment(of: .codex)))
                let status = try await withStopped(rpc, stop: { await $0.shutdown() }) { try await $0.call("getAuthStatus", ["includeToken": true, "refreshToken": false]) }
                guard status["authMethod"]?.string == "chatgpt", let token = status["authToken"]?.string, let access = CodexAccess(token: token) else {
                    throw CodexAccessError.signedOut
                }
                return access
            }
            CodexRuntime.log.notice("Codex credentials: done in \(Self.seconds(since: started), privacy: .public) s")
            return access
        } catch {
            CodexRuntime.log.error("Codex credentials: failed in \(Self.seconds(since: started), privacy: .public) s: \(Self.kind(error), privacy: .public)")
            throw error
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        return String(format: "%.1f", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    /// 错误种类：Codex 回的错误正文不进日志。
    private static func kind(_ error: any Error) -> String {
        switch error {
        case let error as CodexAccessError: "\(error)"
        case CodexRPCError.server(let code, _): "server(\(code))"
        case let error as CodexRPCError: "\(error)"
        case is CancellationError: "cancelled"
        default: "\((error as NSError).domain) \((error as NSError).code)"
        }
    }
}

extension CodexAccess {
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
