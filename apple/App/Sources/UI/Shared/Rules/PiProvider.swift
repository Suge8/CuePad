import CueStore
import SwiftUI

/// 模型的提供方：Pi 的提供方 id（Claude Code、Codex 上报的是 `AgentKind.modelProvider`）→ 显示名与产品标志（`BrandMark`），
/// 全 App 只有这一张表。标志是这家的产品（Anthropic 是 Claude），模型菜单的分组标题与订阅额度的账号共用它；有订阅额度的另有账号名。
/// 没见过的提供方（用户自定义的）用通用图标、名字首字母大写。
nonisolated struct PiProvider: Equatable, Identifiable {
    /// Pi 的提供方 id（`PiModelKey.provider`）。
    let id: String
    let name: String
    /// 这家的产品标志。
    let mark: BrandMark
    /// 订阅账号的产品名（Claude、Codex）：额度按账号显示时用它（`QuotaMeter`）；不是订阅登录的提供方为提供方名。
    let account: String

    init(id: String) {
        self.id = id
        guard let known = Self.known[id.lowercased()] else {
            (name, mark) = (id.prefix(1).uppercased() + id.dropFirst(), .unknown)
            account = name
            return
        }
        (name, mark) = (known.name, known.mark)
        account = known.account ?? known.name
    }

    /// 嵌进文字用：`Text("\(provider.image) Claude")`。
    var image: Image { mark.image }

    /// 提供方 id → 显示名、产品标志与订阅账号名。同一家的几个入口共用一个标志。
    private static let known: [String: (name: String, mark: BrandMark, account: String?)] = [
        "anthropic": ("Anthropic", .claude, "Claude"),
        "openai": ("OpenAI", .openai, nil),
        "openai-codex": ("OpenAI Codex", .codex, "Codex"),
        // Claude Code、Codex 会话上报的模型（`AgentKind.modelProvider`）
        "claude": ("Anthropic", .claude, "Claude"),
        "codex": ("OpenAI", .codex, "Codex"),
        "google": ("Google", .gemini, nil),
        "google-vertex": ("Google Vertex", .gemini, nil),
        "xai": ("xAI", .grok, nil),
        "deepseek": ("DeepSeek", .deepseek, nil),
        "kimi-coding": ("Kimi", .kimi, nil),
        "moonshotai": ("Moonshot AI", .kimi, nil),
        "moonshotai-cn": ("Moonshot AI", .kimi, nil),
        "xiaomi": ("Xiaomi MiMo", .mimo, nil),
        "xiaomi-token-plan-cn": ("Xiaomi MiMo", .mimo, nil),
        "openrouter": ("OpenRouter", .openrouter, nil),
        "opencode": ("OpenCode", .opencode, nil),
        "opencode-go": ("OpenCode", .opencode, nil),
    ]
}

nonisolated extension BrandMark {
    /// 模型的标志：按模型家族，从模型 id 与显示名认（经 OpenRouter、OpenCode 转发的 `anthropic/claude-…`、`google/gemini-…` 也认得）；
    /// 认不出家族时退到提供方的标志，再退到通用图标。
    static func model(id: String, name: String = "", provider: String?) -> BrandMark {
        let words = "\(id) \(name)".lowercased().split { !$0.isLetter && !$0.isNumber }
        for family in families where words.contains(where: { word in family.prefixes.contains { word.hasPrefix($0) } }) { return family.mark }
        if words.contains(where: { $0.wholeMatch(of: /o\d+/) != nil }) { return .openai }
        return provider.map { PiProvider(id: $0).mark } ?? .unknown
    }

    static func model(_ option: PiModelOption) -> BrandMark {
        model(id: option.key.id, name: option.name, provider: option.key.provider)
    }

    /// `provider/model` 写法（子代理名册）；没写提供方时只按家族认。
    static func model(reference: String) -> BrandMark {
        let slash = reference.firstIndex(of: "/")
        return model(id: reference, provider: slash.map { String(reference[..<$0]) })
    }

    /// 模型家族：名字里有一个词（按字母数字切开）以它开头就算。Claude Code 的模型 id 只写 opus、sonnet、haiku；
    /// OpenAI 另有 o 系列（o3、o4-mini，整个词是 o 加数字，写在 `model` 里）。
    private static let families: [(mark: BrandMark, prefixes: [String])] = [
        (.claude, ["claude", "opus", "sonnet", "haiku"]),
        (.openai, ["gpt", "chatgpt"]),
        (.gemini, ["gemini"]),
        (.grok, ["grok"]),
        (.deepseek, ["deepseek"]),
        (.kimi, ["kimi", "moonshot"]),
        (.mimo, ["mimo"]),
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
