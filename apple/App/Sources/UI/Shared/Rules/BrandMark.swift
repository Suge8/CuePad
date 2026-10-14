import SwiftUI

/// 品牌标志，全 App 只此一处：资源名规则、认不出时的通用图标、AppKit 用的图都在这里。规则：标志是产品的，不是公司的——
/// 模型显示它的家族（Claude、GPT、Gemini、Grok…，`BrandMark.model`，规则在 `PiProvider` 旁边）；提供方（模型菜单的分组、
/// 订阅额度的账号）显示它的产品（Anthropic 是 Claude、OpenAI Codex 是 Codex，`PiProvider.mark`）；Agent 显示它自己（`AgentKind.mark`）。
/// 标志是 LobeHub 的单色标志转成的自定义符号（资源目录 Brands 下的 `brand-<名>`，由 design/tools/brand-symbols.py 生成），
/// 与文字基线对齐、随字号缩放、能嵌进 `Text` 插值，颜色跟着前景色走（界面里是次要墨色，系统菜单里是模板图、随菜单文字着色），不用品牌色。
nonisolated struct BrandMark: Hashable, Sendable {
    /// 资源名里 `brand-` 之后那段；nil 是认不出的（通用图标）。
    private let asset: String?

    private init(_ asset: String?) { self.asset = asset }

    // 模型家族（也是订阅账号与提供方分组的标志）
    static let claude = Self("claude")
    static let openai = Self("openai")
    static let gemini = Self("gemini")
    static let grok = Self("grok")
    static let deepseek = Self("deepseek")
    static let kimi = Self("kimi")
    static let mimo = Self("mimo")
    // 转发模型的提供方：认不出家族时退到它
    static let openrouter = Self("openrouter")
    // 接入的 Agent
    static let claudeCode = Self("claudecode")
    static let codex = Self("codex")
    static let opencode = Self("opencode")
    static let pi = Self("pi")
    /// 认不出的（用户自定义的提供方、还不知道是哪个模型）。
    static let unknown = Self(nil)

    private static let generic = "cpu"

    var image: Image { asset.map { Image("brand-" + $0) } ?? Image(systemName: Self.generic) }

    #if os(macOS)
    /// AppKit 菜单项用的同一个标志：符号是模板图。
    var nsImage: NSImage {
        asset.flatMap { NSImage(symbolName: "brand-" + $0, bundle: .main, variableValue: 0) }
            ?? NSImage(systemSymbolName: Self.generic, accessibilityDescription: nil)!
    }
    #endif
}
