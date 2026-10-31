#if DEBUG
import CueStore
import Foundation

/// `-CuePadQuotaSample <样例>`：演示额度换成一处网关报来的账号，形状同 magpie 的真实清单（截图看额度明细的长相，不连真网关）。
/// `magpie`：Claude（max，5 小时用得比匀速快、本周宽松）、DeepSeek 负余额、Codex（pro，credits 与本周）、Grok 本周，都刚观测过。
/// `stress`：同上，另加同一提供方的第二个 Claude 账号查询失败，第一个 Claude 账号的观测已陈旧。
extension DemoLibrary {
    static func seedQuotaSample(_ sample: String, _ store: CueStore) async throws {
        let now = Date.now
        let stress = sample == "stress"
        let source = PiAccount(kind: .apiKey, scope: "demo-gateway", source: "demo-gateway", name: "Magpie")
        func card(_ route: String, _ name: String, user: String, observed: TimeInterval = 60, status: QuotaStatus = .observed,
                  windows: [QuotaWindow] = [], details: String) throws -> QuotaReport {
            let account = PiAccount(kind: .apiKey, scope: "demo-\(route)-\(user)", source: source.source, route: route,
                                    name: ["Magpie", name, user].filter { !$0.isEmpty }.joined(separator: " / "))
            return QuotaReport(provider: route, windows: windows, complete: true, account: account, status: status, observedAt: now.addingTimeInterval(-observed),
                               details: try JSONDecoder().decode(QuotaDetails.self, from: Data(details.utf8)))
        }
        func window(_ seconds: Int, used: Double, left: TimeInterval) -> QuotaWindow { QuotaWindow(seconds: seconds, used: used, resetsAt: now.addingTimeInterval(left)) }
        let (hours5, week) = (5 * 3_600, QuotaWindow.week)
        var accounts = [
            try card("claude", "Claude Code", user: "alice@example.com", observed: stress ? 25 * 60 : 60,
                     windows: [window(hours5, used: 0.58, left: 3 * 3_600), window(week, used: 0.21, left: 86_400 + 5 * 3_600)],
                     details: #"{"kind":"subscription","plan":"max","values":[]}"#),
            try card("deepseek", "DeepSeek", user: "", details: #"{"kind":"balance","balance":"¥-0.06 · $0.00","values":[]}"#),
            try card("codex", "Codex", user: "bob@example.com", windows: [window(week, used: 0.78, left: 5 * 86_400)],
                     details: #"{"kind":"subscription","plan":"pro","balance":"65687.37 credits","values":[]}"#),
            try card("grok", "Grok (SuperGrok)", user: "bob@example.com", windows: [window(week, used: 0.04, left: 2 * 86_400)],
                     details: #"{"kind":"subscription","values":[]}"#),
        ]
        if stress {
            accounts.insert(try card("claude", "Claude Code", user: "carol@example.com", status: .failed, details: #"{"kind":"subscription","plan":"pro","values":[]}"#), at: 1)
        }
        try await store.recordQuota(QuotaReport(provider: "magpie", windows: [], complete: true, account: source, status: .unobserved,
                                                activeScopes: accounts.compactMap(\.account.scope), accounts: accounts, requestedAt: now), host: "demo-mac")
    }
}
#endif
