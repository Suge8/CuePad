import CueStore
import SwiftUI

/// 全 App 只有这一张表；模型菜单的分组标题与订阅额度的账号共用它。
nonisolated struct PiProvider: Equatable, Identifiable {
    let id: String
    let name: String
    let mark: BrandMark?
    let account: String

    init(id: String) {
        self.id = id
        guard let known = Self.known[id.lowercased()] else {
            (name, mark) = (id.prefix(1).uppercased() + id.dropFirst(), nil)
            account = name
            return
        }
        (name, mark) = (known.name, known.mark)
        account = known.account ?? known.name
    }

    private static let known: [String: (name: String, mark: BrandMark, account: String?)] = [
        "anthropic": ("Anthropic", .claude, "Claude"),
        "openai": ("OpenAI", .openai, nil),
        "openai-codex": ("OpenAI Codex", .codex, "Codex"),
        // Claude Code、Codex、Grok Build 会话上报的模型（`AgentKind.modelProvider`）
        "claude": ("Anthropic", .claude, "Claude"),
        "codex": ("OpenAI", .codex, "Codex"),
        "grok": ("xAI", .grok, nil),
        "google": ("Google", .gemini, nil),
        "google-vertex": ("Google Vertex", .gemini, nil),
        "xai": ("xAI", .grok, nil),
        "deepseek": ("DeepSeek", .deepseek, nil),
        // dsh 的两个提供方：API key 与 DeepSeek 账号
        "deepseek-official": ("DeepSeek", .deepseek, nil),
        "deepseek-account": ("DeepSeek", .deepseek, nil),
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
    static func model(id: String, name: String = "", provider: String?) -> BrandMark? {
        let words = "\(id) \(name)".lowercased().split { !$0.isLetter && !$0.isNumber }
        for family in families where words.contains(where: { word in family.prefixes.contains { word.hasPrefix($0) } }) { return family.mark }
        // o1、o3 这类：o 跟数字（不用正则字面量，它每次求值都重新编译）
        if words.contains(where: { $0.count > 1 && $0.first == "o" && $0.dropFirst().allSatisfy(\.isWholeNumber) }) { return .openai }
        return provider.flatMap { PiProvider(id: $0).mark }
    }

    static func model(_ option: PiModelOption) -> BrandMark? {
        model(id: option.key.id, name: option.name, provider: option.key.provider)
    }

    static func model(reference: String) -> BrandMark? {
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

nonisolated enum PiModelName {
    static func short(_ model: String) -> String {
        let id = model.split(separator: "/").last.map(String.init) ?? model
        let name = id.replacing(/^(?i:claude)[\s\-]+/, with: "").replacing(/[\s\-]\d{8}$/, with: "")
        return name.isEmpty ? model : name
    }

    static func short(_ model: PiModelOption) -> String { short(model.displayName) }
}

nonisolated extension PiModelOption {
    var displayName: String { name.isEmpty ? key.id : name }
}
