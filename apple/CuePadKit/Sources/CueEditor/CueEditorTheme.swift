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
