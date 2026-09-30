import CueEditor
import SwiftUI

/// 纸与墨：内容层（卡片、编辑页、列表）的实色。控件层用系统玻璃，不在这里。
/// 增强对比度时加深次要文字与描边。
struct Palette {
    let dark: Bool
    let highContrast: Bool

    init(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        dark = scheme == .dark
        highContrast = contrast == .increased
    }

    var paper: Color { dark ? Color(hex: 0x1F1E1C) : Color(hex: 0xFCFBF8) }
    var desk: Color { dark ? Color(hex: 0x131312) : Color(hex: 0xEFEDE8) }
    var ink: Color { dark ? Color(hex: 0xEEEBE4) : Color(hex: 0x1C1B19) }
    var ink2: Color { ink.opacity(highContrast ? 0.85 : 0.66) }
    var ink3: Color { ink.opacity(highContrast ? 0.7 : 0.42) }
    var hair: Color { (dark ? Color.white : .black).opacity(highContrast ? 0.3 : (dark ? 0.08 : 0.07)) }
    var fill: Color { (dark ? Color.white : .black).opacity(dark ? 0.06 : 0.04) }
    var variable: Color { dark ? Color(hex: 0xE9B872) : Color(hex: 0x98560F) }
    var variableBackground: Color { variable.opacity(dark ? 0.16 : 0.11) }
    /// 实心主按钮（发送）的底与字。
    var solid: Color { ink }
    var onSolid: Color { dark ? .black : .white }

    static func projectTint(_ hex: String) -> Color {
        Color(hex: UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8A8A8A)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// 环境里的配色；根视图按外观与对比度注入。
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(.light)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// 按外观、对比度注入 `palette`，并按设置覆盖明暗。
struct PaletteProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(\.palette, Palette(scheme, contrast: contrast))
    }
}

enum Typeface {
    /// 中文正文一律苹方（与编辑器默认一致）；系统缺该字重时退回系统字体。
    static func pingFang(_ size: CGFloat, weight: CueFont.Weight = .regular) -> CueFont {
        let name = switch weight {
        case .semibold, .bold, .heavy, .black: "PingFangSC-Semibold"
        case .medium: "PingFangSC-Medium"
        default: "PingFangSC-Regular"
        }
        return CueFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension CueEditorTheme {
    /// 编辑页的纸面主题。颜色是固定值而非动态色：外观切换时整体替换主题。
    /// `horizontalInset` 随平台：Mac 纸页宽，iPhone 贴近屏幕边。iOS 上字号是 Dynamic Type 的设计基准。
    static func paper(_ palette: Palette, horizontalInset: CGFloat = 64) -> CueEditorTheme {
        let size: CGFloat = 15.5
        return CueEditorTheme(
            font: Typeface.pingFang(size),
            titleFont: Typeface.pingFang(28, weight: .semibold),
            headingFont: Typeface.pingFang(18, weight: .semibold),
            codeFont: .monospacedSystemFont(ofSize: size - 2, weight: .regular),
            markerColor: CueColor(palette.ink3),
            codeBackground: CueColor(palette.fill),
            textColor: CueColor(palette.ink),
            // 纸由宿主画（带 1px 描边）；编辑器不画底，否则实色底会盖住纸边描边，在编辑区上下沿形成台阶
            backgroundColor: .clear,
            variableColor: CueColor(palette.variable),
            variableBackground: CueColor(palette.variableBackground),
            dividerColor: CueColor(palette.ink3),
            dividerLabelColor: CueColor(palette.ink2),
            placeholderColor: CueColor(palette.fill),
            horizontalInset: horizontalInset,
            verticalInset: 8,
            lineSpacing: 7,
            headingSpacing: 10,
            imageCornerRadius: 10,
            dividerHeight: 32)
    }
}
