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
    public var font: CueFont
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
    public var imageCornerRadius: CGFloat
    public var dividerHeight: CGFloat

    public init(
        font: CueFont, textColor: CueColor, backgroundColor: CueColor, variableColor: CueColor,
        variableBackground: CueColor, dividerColor: CueColor, dividerLabelColor: CueColor,
        placeholderColor: CueColor, horizontalInset: CGFloat, verticalInset: CGFloat, lineSpacing: CGFloat,
        imageCornerRadius: CGFloat, dividerHeight: CGFloat
    ) {
        self.font = font
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
        self.imageCornerRadius = imageCornerRadius
        self.dividerHeight = dividerHeight
    }
}

#if canImport(AppKit)
extension CueEditorTheme {
    /// 中性默认值：系统字体与系统语义色，随外观切换。
    public static let neutral = CueEditorTheme(
        font: .systemFont(ofSize: 15),
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
        imageCornerRadius: 6,
        dividerHeight: 28)
}
#endif
