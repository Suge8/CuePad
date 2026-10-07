import CueEditor
import SwiftUI

/// 纸与墨：内容层（卡片、编辑页、列表）的实色与全部颜色 token。控件层用系统玻璃，不在这里。
///
/// **强调色是墨**：品牌（logo、吉祥物）只有纸与墨两种颜色。主按钮、选中、焦点一律用墨，
/// 这样界面上出现的彩色只有两种意思——要你注意的状态（等你确认橙、出错红）和项目身份（项目图标）——一眼能读懂。
/// 深色是"夜里的纸"：暖黑的桌面、同一色温略亮的纸、更深一档的侧栏，三层靠明度分开，不用中性灰或冷蓝。
/// 增强对比度时加深次要文字与描边。
struct Palette {
    let dark: Bool
    let highContrast: Bool

    init(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        dark = scheme == .dark
        highContrast = contrast == .increased
    }

    // MARK: 层（由后到前：侧栏 → 桌面 → 纸）

    var sidebar: Color { dark ? Color(hex: 0x141210) : Color(hex: 0xE6E2DB) }
    var desk: Color { dark ? Color(hex: 0x1B1916) : Color(hex: 0xEFEDE8) }
    var paper: Color { dark ? Color(hex: 0x282420) : Color(hex: 0xFCFBF8) }

    // MARK: 墨

    var ink: Color { dark ? Color(hex: 0xEEE9E1) : Color(hex: 0x1C1B19) }
    var ink2: Color { ink.opacity(highContrast ? 0.85 : 0.68) }
    var ink3: Color { ink.opacity(highContrast ? 0.7 : 0.45) }
    var hair: Color { (dark ? Color.white : .black).opacity(highContrast ? 0.3 : (dark ? 0.09 : 0.07)) }
    var fill: Color { (dark ? Color.white : .black).opacity(dark ? 0.06 : 0.04) }

    // MARK: 强调（墨）

    /// 主按钮底色、焦点、可点击的强调文字。
    var accent: Color { ink }
    /// 主按钮上的字。
    var onAccent: Color { paper }
    /// 选中底色：侧栏与列表的当前项用它垫一层墨色浅底，文字保持墨色并加粗；Mac 与 iOS 共用，不用系统灰胶囊。
    var selection: Color { ink.opacity(dark ? 0.14 : 0.09) }

    // MARK: 你的话（会话里你发出的气泡，iOS 与 Mac 共用）

    /// 气泡底：浅色是墨底纸字；深色的墨是浅奶油，整块实底在暗处刺眼，改用比纸略抬升的暖深色、字仍是墨。
    var bubble: Color { dark ? Color(hex: 0x3A352F) : ink }
    /// 气泡上的字。
    var onBubble: Color { dark ? ink : paper }
    /// 气泡的描边：深色下气泡与纸、桌面明度接近，加一圈低对比的线把边界提出来；浅色不用。
    var bubbleEdge: Color { dark ? Color.white.opacity(highContrast ? 0.22 : 0.08) : .clear }

    // MARK: 状态（只表达含义，不给文字大面积上色）

    /// 等你确认、需要处理。
    var attention: Color { dark ? Color(hex: 0xF0A44B) : Color(hex: 0xC9711A) }
    /// 出错。
    var failure: Color { dark ? Color(hex: 0xF07A6A) : Color(hex: 0xC23B2B) }

    // MARK: 正文里的变量（朱砂色标注）

    var variable: Color { dark ? Color(hex: 0xE9B872) : Color(hex: 0x98560F) }
    var variableBackground: Color { variable.opacity(dark ? 0.16 : 0.11) }

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

/// 按外观、对比度注入 `palette`，并把强调色（墨）设为系统控件的 tint：选中、焦点、开关都用它。
struct PaletteProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let palette = Palette(scheme, contrast: contrast)
        content.environment(\.palette, palette).tint(palette.accent)
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
