import CueEditor
import SwiftUI

/// 一样东西此刻要不要你注意（同步、Pi 连接、命令行、崩溃这类状态），全 App 着色只按它：平静是次要墨色；要你处理是墨色，
/// 靠图形与比平静更深的字抢眼（赭黄只留给 Agent 等你确认）；出错是胭脂。
nonisolated enum StatusTone: Equatable {
    case calm, notice, failure
}

extension Palette {
    /// 状态的颜色；`muted` 是写在名称下面的那行状态字，平静时比图标再淡一级。
    func color(_ tone: StatusTone, muted: Bool = false) -> Color {
        switch tone {
        case .calm: muted ? ink3 : ink2
        case .notice: ink
        case .failure: failure
        }
    }
}

/// App 窗口的根：注入配色（`withPalette`）。
struct PaletteProvider: ViewModifier {
    func body(content: Content) -> some View {
        content.withPalette()
            // 验收时整个窗口按"减弱动态效果"画（`-CuePadReduceMotion`）：不碰系统设置，Mac 上那是用户这台机器的全局设置
            .transformEnvironment(\._accessibilityReduceMotion) { if DebugHooks.preset.reducesMotion { $0 = true } }
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
    /// 编辑页的主题。颜色是固定值而非动态色：外观切换时整体替换主题。
    /// 左右留白随平台：Mac 编辑页铺满、字限在 `maxTextWidth` 一列里居中，iPhone 贴近屏幕边。iOS 上字号是 Dynamic Type 的设计基准。
    static func editor(_ palette: Palette, horizontalInset: CGFloat, maxTextWidth: CGFloat? = nil) -> CueEditorTheme {
        let size: CGFloat = 15.5
        return CueEditorTheme(
            font: Typeface.pingFang(size),
            headingFont: Typeface.pingFang(18, weight: .semibold),
            codeFont: .monospacedSystemFont(ofSize: size - 2, weight: .regular),
            markerColor: CueColor(palette.ink3),
            codeBackground: CueColor(palette.fill),
            textColor: CueColor(palette.ink),
            // 底色由宿主画（Mac 是页面底色，iPhone 是纸色）；编辑器不画底，下沿的淡出才透得出宿主的底
            backgroundColor: .clear,
            variableColor: CueColor(palette.ink),
            variableBackground: CueColor(palette.fill),
            imagePlaceholderColor: CueColor(palette.fill),
            horizontalInset: horizontalInset,
            maxTextWidth: maxTextWidth,
            verticalInset: 8,
            lineSpacing: 7,
            headingSpacing: 10,
            imageCornerRadius: 10)
    }
}
