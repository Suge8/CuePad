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

// NSFont/NSColor 未标 Sendable，但主题只保存不可变的样式值。
public struct CueEditorTheme: @unchecked Sendable {
    public var font: CueFont
    /// `# ` `## ` 等标题行的字体（各级同一个）。
    public var headingFont: CueFont
    public var codeFont: CueFont
    /// 标题、列表、围栏等标记字符的颜色：保持可见，降低存在感。
    public var markerColor: CueColor
    public var codeBackground: CueColor
    public var textColor: CueColor
    public var backgroundColor: CueColor
    public var variableColor: CueColor
    public var variableBackground: CueColor
    public var imagePlaceholderColor: CueColor
    public var horizontalInset: CGFloat
    /// 一行字最宽多少（AppKit）：编辑区更宽时左右留白加大，让这一列字居中；nil 时只有 `horizontalInset`。
    public var maxTextWidth: CGFloat?
    public var verticalInset: CGFloat
    public var lineSpacing: CGFloat
    public var headingSpacing: CGFloat
    public var imageCornerRadius: CGFloat

    public init(
        font: CueFont, headingFont: CueFont, codeFont: CueFont, markerColor: CueColor,
        codeBackground: CueColor, textColor: CueColor, backgroundColor: CueColor, variableColor: CueColor,
        variableBackground: CueColor, imagePlaceholderColor: CueColor, horizontalInset: CGFloat, maxTextWidth: CGFloat? = nil, verticalInset: CGFloat, lineSpacing: CGFloat,
        headingSpacing: CGFloat, imageCornerRadius: CGFloat
    ) {
        self.font = font
        self.headingFont = headingFont
        self.codeFont = codeFont
        self.markerColor = markerColor
        self.codeBackground = codeBackground
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.variableColor = variableColor
        self.variableBackground = variableBackground
        self.imagePlaceholderColor = imagePlaceholderColor
        self.horizontalInset = horizontalInset
        self.maxTextWidth = maxTextWidth
        self.verticalInset = verticalInset
        self.lineSpacing = lineSpacing
        self.headingSpacing = headingSpacing
        self.imageCornerRadius = imageCornerRadius
    }
}
