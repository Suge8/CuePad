import CueStore
import SwiftUI

/// 模型的提供方：Pi 的提供方 id → 显示名与图标，全 App 只有这一张表。图标是 LobeHub 的单色标志转成的自定义符号
/// （资源目录的 Providers 下，由 design/tools/provider-symbols.py 生成），与文字基线对齐、随字号缩放、能嵌进 `Text` 插值，
/// 颜色跟着前景色走（界面里是次要墨色，系统菜单里随菜单文字的颜色，不用品牌色）。没见过的提供方（用户自定义的）用通用图标、名字首字母大写。
nonisolated struct PiProvider: Equatable, Identifiable {
    /// Pi 的提供方 id（`PiModelKey.provider`）。
    let id: String
    let name: String
    /// 订阅账号的产品名（Claude、Codex）：额度按账号显示时用它（`QuotaMeter`）；不是订阅登录的提供方为提供方名。
    let account: String
    /// 资源目录里的符号名；nil 是没见过的提供方。
    private let symbol: String?

    init(id: String) {
        self.id = id
        if let known = Self.known[id.lowercased()] {
            (name, symbol) = (known.name, "provider-" + known.icon)
            account = known.account ?? known.name
        } else {
            (name, symbol) = (id.prefix(1).uppercased() + id.dropFirst(), nil)
            account = name
        }
    }

    /// `provider/model` 写法（子代理名册）里的提供方；没写提供方时为 nil。
    init?(reference: String) {
        guard let slash = reference.firstIndex(of: "/") else { return nil }
        self.init(id: String(reference[..<slash]))
    }

    /// 嵌进文字用：`Text("\(provider.image) opus-5-5")`。
    var image: Image { symbol.map { Image($0) } ?? Self.unknown }

    /// 通用图标：没见过的提供方，以及还不知道是哪个模型时。
    static var unknown: Image { Image(systemName: generic) }

    #if os(macOS)
    /// AppKit 菜单项用的同一个图标。
    var nsImage: NSImage? {
        symbol.flatMap { NSImage(symbolName: $0, bundle: .main, variableValue: 0) }
            ?? NSImage(systemSymbolName: Self.generic, accessibilityDescription: nil)
    }
    #endif

    private static let generic = "cpu"

    /// 提供方 id → 显示名与图标（`provider-<图标>`），有订阅额度的另有账号的产品名。同一家的几个入口共用一个图标。
    private static let known: [String: (name: String, icon: String, account: String?)] = [
        "anthropic": ("Anthropic", "anthropic", "Claude"),
        "openai": ("OpenAI", "openai", nil),
        "openai-codex": ("OpenAI Codex", "openai", "Codex"),
        // Codex 会话上报的模型（`AgentKind.modelProvider`）
        "codex": ("Codex", "openai", "Codex"),
        "google": ("Google", "gemini", nil),
        "google-vertex": ("Google Vertex", "gemini", nil),
        "xai": ("xAI", "xai", nil),
        "deepseek": ("DeepSeek", "deepseek", nil),
        "kimi-coding": ("Kimi", "kimi", nil),
        "moonshotai": ("Moonshot AI", "kimi", nil),
        "moonshotai-cn": ("Moonshot AI", "kimi", nil),
        "xiaomi": ("Xiaomi MiMo", "mimo", nil),
        "xiaomi-token-plan-cn": ("Xiaomi MiMo", "mimo", nil),
        "openrouter": ("OpenRouter", "openrouter", nil),
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
