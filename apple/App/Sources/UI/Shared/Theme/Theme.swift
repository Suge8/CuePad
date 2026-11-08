import CueEditor
import SwiftUI

/// 一样东西此刻要不要你注意（同步、Pi 连接、命令行、崩溃这类状态），全 App 着色只按它：平静是次要墨色；要你处理是墨色，
/// 靠图形与比平静更深的字抢眼（赭黄只留给 Agent 等你确认）；出错是胭脂。
nonisolated enum StatusTone: Equatable {
    case calm, notice, failure
}

extension TextField where Label == Text {
    /// 自己画底的一行输入（纸、玻璃上）：占位字用第三档墨色。系统的占位灰在纸与玻璃上不到 4.5:1，与输入框里的占位字也不同深（docs/ui.md）。
    init(_ prompt: String, text: Binding<String>, palette: Palette, axis: Axis = .horizontal) {
        self.init(text: text, prompt: Text(prompt).foregroundStyle(palette.ink3), axis: axis) { Text(prompt) }
    }
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

/// App 窗口的根：系统控件按墨着色（`withPalette`），验收时按启动参数改外观环境。配色本身随外观算出，不在这里注入（`EnvironmentValues.palette`）。
struct PaletteProvider: ViewModifier {
    func body(content: Content) -> some View {
        content.withPalette()
            // 验收时整个窗口按"减弱动态效果"画（`-CuePadReduceMotion`）：不碰系统设置，Mac 上那是用户这台机器的全局设置
            .transformEnvironment(\._accessibilityReduceMotion) { if DebugHooks.preset.reducesMotion { $0 = true } }
            // 同理按最大的辅助字号画（`-CuePadLargestType`）
            .transformEnvironment(\.dynamicTypeSize) { if DebugHooks.preset.largestType { $0 = .accessibility5 } }
            // 同理按"增强对比度"画（`-CuePadHighContrast`）
            .transformEnvironment(\._colorSchemeContrast) { if DebugHooks.preset.highContrast { $0 = .increased } }
    }
}

extension CueEditorTheme {
    /// 灵感直接编辑 Markdown；标题前不叠段距，源码空行仍保留。
    static func inspiration(_ palette: Palette, horizontalInset: CGFloat, maxTextWidth: CGFloat? = nil) -> CueEditorTheme {
        var theme = editor(palette, horizontalInset: horizontalInset, verticalInset: Spacing.group, maxTextWidth: maxTextWidth)
        theme.headingSpacing = 0
        theme.blankLineHeight = Spacing.tight
        return theme
    }

    /// 编辑页的主题。颜色是固定值而非动态色：外观切换时整体替换主题。
    /// 左右留白随平台：Mac 编辑页铺满、字限在 `maxTextWidth` 一列里居中，iPhone 贴近屏幕边。iOS 上字号是 Dynamic Type 的设计基准。
    /// `verticalInset` 是首行上面与末行下面的留白：宽屏 iPad 的纸四边同宽，其余贴着顶栏，留一点就够。
    static func editor(_ palette: Palette, horizontalInset: CGFloat, verticalInset: CGFloat = 8, maxTextWidth: CGFloat? = nil) -> CueEditorTheme {
        return CueEditorTheme(
            font: Typography.readingFont,
            headingFont: Typography.editorHeadingFont,
            codeFont: Typography.editorCodeFont,
            captionFont: Typography.editorCaptionFont,
            fileGlyphSize: Glyph.largeSize,
            markerColor: CueColor(palette.ink3),
            codeBackground: CueColor(palette.fill),
            textColor: CueColor(palette.ink),
            // 底色由宿主画（Mac 是页面底色，iPhone 是纸色）；编辑器透明
            backgroundColor: .clear,
            variableColor: CueColor(palette.ink),
            variableBackground: CueColor(palette.fill),
            imagePlaceholderColor: CueColor(palette.fill),
            horizontalInset: horizontalInset,
            maxTextWidth: maxTextWidth,
            verticalInset: verticalInset,
            lineSpacing: Typography.readingLineSpacing,
            headingSpacing: Typography.editorHeadingSpacing,
            imageCornerRadius: Radius.block)
    }
}
