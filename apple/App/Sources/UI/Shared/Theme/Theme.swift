import CueEditor
import SwiftUI

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

struct PaletteProvider: ViewModifier {
    func body(content: Content) -> some View {
        content.withPalette()
            // 验收时整个窗口按"减弱动态效果"、"降低透明度"画（`-CuePadReduceMotion`、`-CuePadReduceTransparency`）：不碰系统设置，Mac 上那是用户这台机器的全局设置
            .transformEnvironment(\._accessibilityReduceMotion) { if DebugHooks.args.layoutOpts.reduceMotion { $0 = true } }
            .transformEnvironment(\._accessibilityReduceTransparency) { if DebugHooks.args.layoutOpts.reduceTransparency { $0 = true } }
            .transformEnvironment(\.dynamicTypeSize) { if DebugHooks.args.layoutOpts.largestType { $0 = .accessibility5 } }
            .transformEnvironment(\._colorSchemeContrast) { if DebugHooks.args.layoutOpts.highContrast { $0 = .increased } }
    }
}

extension CueEditorTheme {
    static func inspiration(_ palette: Palette, horizontalInset: CGFloat, maxTextWidth: CGFloat? = nil) -> CueEditorTheme {
        var theme = editor(palette, horizontalInset: horizontalInset, verticalInset: Spacing.group, maxTextWidth: maxTextWidth)
        theme.headingSpacing = 0
        return theme
    }

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
