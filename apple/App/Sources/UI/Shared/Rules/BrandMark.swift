import SwiftUI

/// 品牌标志，全 App 只此一处：资源名规则、AppKit 用的图都在这里。规则：标志是产品的，不是公司的——
/// 模型显示它的家族（Claude、GPT、Gemini、Grok…，`BrandMark.model`，规则在 `Provider` 旁边）；提供方（模型菜单的分组、
/// 订阅额度的账号）显示它的产品（Anthropic 是 Claude、OpenAI Codex 是 Codex，`Provider.mark`）；Agent 显示它自己（`AgentKind.mark`）。
/// 认不出的（用户自定义的提供方与它的模型）不带标志，只写名字：通用图标说不出是哪一家，在模型胶囊上还被读成"默认模型"。
/// 标志是 LobeHub 的单色标志转成的自定义符号（资源目录 Brands 下的 `brand-<名>`，由 design/tools/brand-symbols.py 生成），
/// 能嵌进 `Text` 插值；颜色跟着前景色走（系统菜单里是模板图），不用品牌色。
nonisolated struct BrandMark: Hashable, Sendable {
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
    static let claudeCode = Self("claudecode")
    static let codex = Self("codex")
    static let opencode = Self("opencode")
    static let pi = Self("pi")

    /// 装饰图：名字总在旁边或在所在元素的标签里，读屏不念资源名（同 `Icon`）。
    var image: Image { Image(decorative: "brand-" + asset) }

    static func label(_ mark: BrandMark?, _ name: String) -> Text {
        mark.map { Text("\($0.image) \(name)") } ?? Text(name)
    }

    #if os(iOS)
    var uiImage: UIImage? { UIImage(named: "brand-" + asset) }
    #else
    var nsImage: NSImage? { NSImage(symbolName: "brand-" + asset, bundle: .main, variableValue: 0) }
    #endif
}

/// "这家读不到"：标志压一道斜杠（同系统符号的 `.slash` 变体，一眼读作"没有"），斜杠两侧挖开一道缝，叠在纸上、行的悬停底上都分得开。
struct StruckBrandMark: View {
    let mark: BrandMark
    let size: CGFloat

    var body: some View {
        let line = max(1, size / 10)
        mark.image.font(.system(size: size))
            .mask {
                Rectangle().overlay { Self.slash(width: line * 3).blendMode(.destinationOut) }.compositingGroup()
            }
            .overlay { Self.slash(width: line) }
    }

    /// 斜杠两头比标志伸出这么多：压过标志的上下沿，读作划掉整个标志、不是标志里的一笔。
    private static let slashReach: CGFloat = 2

    private static func slash(width: CGFloat) -> some View {
        Capsule().frame(width: width).padding(.vertical, -Self.slashReach).rotationEffect(.degrees(-45))
    }
}
