import CueStore
import SwiftUI

/// 模型的提供方：Pi 的提供方 id（Claude Code、Codex 上报的是 `AgentKind.modelProvider`）→ 显示名与标志（`BrandMark`），
/// 全 App 只有这一张表。模型显示做模型的那家；有订阅额度的另有账号（产品名与产品标志：Claude、Codex）。
/// 没见过的提供方（用户自定义的）用通用图标、名字首字母大写。
nonisolated struct PiProvider: Equatable, Identifiable {
    /// Pi 的提供方 id（`PiModelKey.provider`）。
    let id: String
    let name: String
    /// 做模型的那家的标志。
    let mark: BrandMark
    /// 订阅账号的产品名（Claude、Codex）：额度按账号显示时用它（`QuotaMeter`）；不是订阅登录的提供方为提供方名。
    let account: String
    /// 订阅账号的产品标志（额度的仪表）；不是订阅登录的提供方为做模型的那家。
    let accountMark: BrandMark

    init(id: String) {
        self.id = id
        guard let known = Self.known[id.lowercased()] else {
            (name, mark) = (id.prefix(1).uppercased() + id.dropFirst(), .unknown)
            (account, accountMark) = (name, mark)
            return
        }
        (name, mark) = (known.name, known.mark)
        (account, accountMark) = known.account ?? (name, mark)
    }

    /// `provider/model` 写法（子代理名册）里的提供方；没写提供方时为 nil。
    init?(reference: String) {
        guard let slash = reference.firstIndex(of: "/") else { return nil }
        self.init(id: String(reference[..<slash]))
    }

    /// 嵌进文字用：`Text("\(provider.image) opus-5-5")`。
    var image: Image { mark.image }

    /// 还不知道是哪个模型时。
    static var unknown: Image { BrandMark.unknown.image }

    private static let claude = (name: "Claude", mark: BrandMark.claude)
    private static let codex = (name: "Codex", mark: BrandMark.codex)

    /// 提供方 id → 显示名与做模型那家的标志，有订阅额度的另有账号。同一家的几个入口共用一个标志。
    private static let known: [String: (name: String, mark: BrandMark, account: (name: String, mark: BrandMark)?)] = [
        "anthropic": ("Anthropic", .anthropic, claude),
        "openai": ("OpenAI", .openai, nil),
        "openai-codex": ("OpenAI Codex", .openai, codex),
        // Claude Code、Codex 会话上报的模型（`AgentKind.modelProvider`）
        "claude": ("Anthropic", .anthropic, claude),
        "codex": ("OpenAI", .openai, codex),
        "google": ("Google", .gemini, nil),
        "google-vertex": ("Google Vertex", .gemini, nil),
        "xai": ("xAI", .xai, nil),
        "deepseek": ("DeepSeek", .deepseek, nil),
        "kimi-coding": ("Kimi", .kimi, nil),
        "moonshotai": ("Moonshot AI", .kimi, nil),
        "moonshotai-cn": ("Moonshot AI", .kimi, nil),
        "xiaomi": ("Xiaomi MiMo", .mimo, nil),
        "xiaomi-token-plan-cn": ("Xiaomi MiMo", .mimo, nil),
        "openrouter": ("OpenRouter", .openrouter, nil),
    ]
}

/// 模型的短名（回复框下的模型胶囊、会话行、子代理）：去掉提供方前缀、Anthropic 模型名开头的 Claude、末尾的日期戳，
/// "anthropic/claude-opus-5-5-20260901" 写成 "opus-5-5"，"Claude Opus 5.5" 写成 "Opus 5.5"。
nonisolated enum PiModelName {
    static func short(_ model: String) -> String {
        let id = model.split(separator: "/").last.map(String.init) ?? model
        let name = id.replacing(/^(?i:claude)[\s\-]+/, with: "").replacing(/[\s\-]\d{8}$/, with: "")
        return name.isEmpty ? model : name
    }

    /// 有显示名用显示名，没有用 id。
    static func short(_ model: PiModelOption) -> String {
        short(model.name.isEmpty ? model.key.id : model.name)
    }
}
