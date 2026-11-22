import SwiftUI

nonisolated struct BrandMark: Hashable, Sendable {
    private let asset: String

    private init(_ asset: String) { self.asset = asset }

    static let claude = Self("claude")
    static let openai = Self("openai")
    static let gemini = Self("gemini")
    static let grok = Self("grok")
    static let deepseek = Self("deepseek")
    static let kimi = Self("kimi")
    static let mimo = Self("mimo")
    static let openrouter = Self("openrouter")
    static let claudeCode = Self("claudecode")
    static let codex = Self("codex")
    static let opencode = Self("opencode")
    static let pi = Self("pi")

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

    private static let slashReach: CGFloat = 2

    private static func slash(width: CGFloat) -> some View {
        Capsule().frame(width: width).padding(.vertical, -Self.slashReach).rotationEffect(.degrees(-45))
    }
}
