import CoreGraphics

#if canImport(AppKit)
import AppKit
public typealias CueColor = NSColor
public typealias CueFont = NSFont
#elseif canImport(UIKit)
import UIKit
public typealias CueColor = UIColor
public typealias CueFont = UIFont
#endif

/// 编辑器的全部样式参数。视觉方向确定后只需提供新的主题值。
// NSFont/NSColor 未标 Sendable，但主题只保存不可变的样式值。
public struct CueEditorTheme: @unchecked Sendable {
    /// 正文字体。
    public var font: CueFont
    /// 首个非空行（卡片标题）的字体。
    public var titleFont: CueFont
    /// `## ` 标题行的字体。
    public var headingFont: CueFont
    /// 代码块与行内 code 的字体。
    public var codeFont: CueFont
    /// 标题、列表、围栏等标记字符的颜色：保持可见，降低存在感。
    public var markerColor: CueColor
    /// 代码块整行底色与行内 code 底色。
    public var codeBackground: CueColor
    public var textColor: CueColor
    public var backgroundColor: CueColor
    public var variableColor: CueColor
    public var variableBackground: CueColor
    public var dividerColor: CueColor
    public var dividerLabelColor: CueColor
    /// 图片加载中或缺失时的底色。
    public var placeholderColor: CueColor
    public var horizontalInset: CGFloat
    public var verticalInset: CGFloat
    public var lineSpacing: CGFloat
    /// `## ` 标题行上方的额外间距。
    public var headingSpacing: CGFloat
    public var imageCornerRadius: CGFloat
    public var dividerHeight: CGFloat

    public init(
        font: CueFont, titleFont: CueFont, headingFont: CueFont, codeFont: CueFont, markerColor: CueColor,
        codeBackground: CueColor, textColor: CueColor, backgroundColor: CueColor, variableColor: CueColor,
        variableBackground: CueColor, dividerColor: CueColor, dividerLabelColor: CueColor,
        placeholderColor: CueColor, horizontalInset: CGFloat, verticalInset: CGFloat, lineSpacing: CGFloat, headingSpacing: CGFloat,
        imageCornerRadius: CGFloat, dividerHeight: CGFloat
    ) {
        self.font = font
        self.titleFont = titleFont
        self.headingFont = headingFont
        self.codeFont = codeFont
        self.markerColor = markerColor
        self.codeBackground = codeBackground
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.variableColor = variableColor
        self.variableBackground = variableBackground
        self.dividerColor = dividerColor
        self.dividerLabelColor = dividerLabelColor
        self.placeholderColor = placeholderColor
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.lineSpacing = lineSpacing
        self.headingSpacing = headingSpacing
        self.imageCornerRadius = imageCornerRadius
        self.dividerHeight = dividerHeight
    }
}

#if canImport(AppKit)
extension CueEditorTheme {
    /// 中性默认值：系统字体与系统语义色，随外观切换。
    public static let neutral = CueEditorTheme(
        font: .pingFang(15),
        titleFont: .pingFang(22, weight: .semibold),
        headingFont: .pingFang(18, weight: .semibold),
        codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        markerColor: .tertiaryLabelColor,
        codeBackground: CueColor.labelColor.withAlphaComponent(0.06),
        textColor: .labelColor,
        backgroundColor: .textBackgroundColor,
        variableColor: .systemPurple,
        variableBackground: CueColor.systemPurple.withAlphaComponent(0.12),
        dividerColor: .tertiaryLabelColor,
        dividerLabelColor: .secondaryLabelColor,
        placeholderColor: .quaternaryLabelColor,
        horizontalInset: 20,
        verticalInset: 16,
        lineSpacing: 3,
        headingSpacing: 8,
        imageCornerRadius: 6,
        dividerHeight: 28)
}

extension NSFont {
    /// 中文正文一律苹方；系统未提供该字重时退回系统字体。
    static func pingFang(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "PingFangSC-Semibold"
        case .medium: name = "PingFangSC-Medium"
        default: name = "PingFangSC-Regular"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
#endif
