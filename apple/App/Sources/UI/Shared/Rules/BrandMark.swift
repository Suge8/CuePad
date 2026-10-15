import SwiftUI

/// 品牌标志，全 App 只此一处：资源名规则、AppKit 用的图都在这里。规则：标志是产品的，不是公司的——
/// 模型显示它的家族（Claude、GPT、Gemini、Grok…，`BrandMark.model`，规则在 `PiProvider` 旁边）；提供方（模型菜单的分组、
/// 订阅额度的账号）显示它的产品（Anthropic 是 Claude、OpenAI Codex 是 Codex，`PiProvider.mark`）；Agent 显示它自己（`AgentKind.mark`）。
/// 认不出的（用户自定义的提供方与它的模型）不带标志，只写名字：通用图标（曾是芯片）说不出是哪一家，在模型胶囊上还被读成"默认模型"。
/// 标志是 LobeHub 的单色标志转成的自定义符号（资源目录 Brands 下的 `brand-<名>`，由 design/tools/brand-symbols.py 生成），
/// 与文字基线对齐、随字号缩放、能嵌进 `Text` 插值，颜色跟着前景色走（界面里是次要墨色，系统菜单里是模板图、随菜单文字着色），不用品牌色。
nonisolated struct BrandMark: Hashable, Sendable {
    /// 资源名里 `brand-` 之后那段。
    private let asset: String

    private init(_ asset: String) { self.asset = asset }

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

    var image: Image { Image("brand-" + asset) }

    /// 嵌在一行字里的"标志 名字"；没有标志只写名字。
    static func label(_ mark: BrandMark?, _ name: String) -> Text {
        mark.map { Text("\($0.image) \(name)") } ?? Text(name)
    }

    #if os(iOS)
    /// UIKit 菜单项用的同一个标志（`MenuButton`）。
    var uiImage: UIImage? { UIImage(named: "brand-" + asset) }
    #else
    /// AppKit 菜单项用的同一个标志：符号是模板图。
    var nsImage: NSImage? { NSImage(symbolName: "brand-" + asset, bundle: .main, variableValue: 0) }
    #endif
}
