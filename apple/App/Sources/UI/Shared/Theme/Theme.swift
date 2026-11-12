import CueEditor
import SwiftUI

/// 一样东西此刻要不要你注意（同步、Pi 连接、命令行、崩溃这类状态），全 App 着色只按它：平静是次要墨色；要你处理是墨色，
/// 靠图形与比平静更深的字抢眼（赭黄只留给 Agent 等你确认，和会话里缓存失效那一行的感叹号）；出错是胭脂。
nonisolated enum StatusTone: Equatable {
    case calm, notice, failure
}

extension TextField where Label == Text {
    /// 自己画底的一行输入（纸、玻璃上）：占位字用第三档墨色。系统的占位灰在纸与玻璃上不到 4.5:1，与输入框里的占位字也不同深。
    init(_ prompt: String, text: Binding<String>, palette: Palette, axis: Axis = .horizontal) {
        self.init(text: text, prompt: Text(prompt).foregroundStyle(palette.ink3), axis: axis) { Text(prompt) }
    }
}

extension Palette {
    func color(_ tone: StatusTone, muted: Bool = false) -> Color {
        switch tone {
        case .calm: muted ? ink3 : ink2
        case .notice: ink
        case .failure: failure
        }
    }
}

/// 配色本身随外观算出，不在这里注入（`EnvironmentValues.palette`）。
struct PaletteProvider: ViewModifier {
    func body(content: Content) -> some View {
        content.withPalette()
            // 验收时整个窗口按"减弱动态效果"画（`-CuePadReduceMotion`）：不碰系统设置，Mac 上那是用户这台机器的全局设置
            .transformEnvironment(\._accessibilityReduceMotion) { if DebugHooks.preset.reducesMotion { $0 = true } }
            .transformEnvironment(\.dynamicTypeSize) { if DebugHooks.preset.largestType { $0 = .accessibility5 } }
            .transformEnvironment(\._colorSchemeContrast) { if DebugHooks.preset.highContrast { $0 = .increased } }
    }
}

extension CueEditorTheme {
    static func inspiration(_ palette: Palette, horizontalInset: CGFloat, maxTextWidth: CGFloat? = nil) -> CueEditorTheme {
        var theme = editor(palette, horizontalInset: horizontalInset, verticalInset: Spacing.group, maxTextWidth: maxTextWidth)
        theme.headingSpacing = 0
        theme.blankLineHeight = Spacing.tight
        return theme
    }

    /// 编辑页的主题。颜色是固定值而非动态色：外观切换时整体替换主题。
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
