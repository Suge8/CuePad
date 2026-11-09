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
public struct CueEditorTheme: Equatable, @unchecked Sendable {
    public var font: CueFont
    /// `# ` `## ` 等标题行的字体（各级同一个）。
    public var headingFont: CueFont
    public var codeFont: CueFont
    /// 图片占位中间的说明字（图片缺失、传了几成）。
    public var captionFont: CueFont
    public var fileGlyphSize: CGFloat
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
    /// 源码空段的显示高度；nil 沿用正文行高，不改存储与撤销。
    public var blankLineHeight: CGFloat?
    public var headingSpacing: CGFloat
    public var imageCornerRadius: CGFloat
    /// 首段当标题排（任务气泡：标题与下面的话在同一个编辑器里，从第一帧就可编辑，点哪光标落在哪）；nil 时首段同正文。
    public var title: Title?

    /// 首段的样子：字体（按 `title3` 的档位随系统字号缩放）、颜色，与下一段隔多远。只改展示，存储格式里它就是第一行。
    public struct Title: Equatable, @unchecked Sendable {
        public var font: CueFont
        public var color: CueColor
        public var spacing: CGFloat

        public init(font: CueFont, color: CueColor, spacing: CGFloat) {
            self.font = font
            self.color = color
            self.spacing = spacing
        }
    }

    public init(
        font: CueFont, headingFont: CueFont, codeFont: CueFont, captionFont: CueFont, fileGlyphSize: CGFloat, markerColor: CueColor,
        codeBackground: CueColor, textColor: CueColor, backgroundColor: CueColor, variableColor: CueColor,
        variableBackground: CueColor, imagePlaceholderColor: CueColor, horizontalInset: CGFloat, maxTextWidth: CGFloat? = nil, verticalInset: CGFloat, lineSpacing: CGFloat,
        headingSpacing: CGFloat, imageCornerRadius: CGFloat
    ) {
        self.font = font
        self.headingFont = headingFont
        self.codeFont = codeFont
        self.captionFont = captionFont
        self.fileGlyphSize = fileGlyphSize
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

#if canImport(UIKit)
extension CueEditorTheme {
    /// 编辑器与只读预览按同一份系统文字样式缩放，主题本身始终保留默认档位的值。
    public func scaled(for traits: UITraitCollection) -> Self {
        func font(_ value: UIFont, fallback: UIFont.TextStyle) -> UIFont {
            // 固定系统字体的 textStyle 也可能是 CTFontRegularUsage；它不是 UIFontMetrics 接受的文字样式。
            let styles: [UIFont.TextStyle] = [.body, .callout, .caption1, .caption2, .footnote, .headline, .subheadline, .largeTitle, .title1, .title2, .title3, .extraLargeTitle, .extraLargeTitle2]
            let rawStyle = value.fontDescriptor.object(forKey: .textStyle) as? String
            if let style = styles.first(where: { $0.rawValue == rawStyle }) {
                // 系统文字样式有自己的字号表；Metrics 缩放固定字号不等于目标档位的 preferredFont。
                guard let fontTraits = value.fontDescriptor.fontAttributes[.traits] else {
                    return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
                }
                let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style, compatibleWith: traits)
                    .addingAttributes([.traits: fontTraits])
                return UIFont(descriptor: descriptor, size: 0)
            }
            let scaled = UIFontMetrics(forTextStyle: fallback).scaledFont(for: value, compatibleWith: traits)
            return scaled.pointSize == value.pointSize ? value : scaled
        }
        func spacing(_ value: CGFloat) -> CGFloat {
            UIFontMetrics(forTextStyle: .body).scaledValue(for: value, compatibleWith: traits)
        }
        var result = self
        result.font = font(self.font, fallback: .body)
        result.headingFont = font(headingFont, fallback: .title3)
        result.codeFont = font(codeFont, fallback: .footnote)
        result.captionFont = font(captionFont, fallback: .caption1)
        result.lineSpacing = spacing(lineSpacing)
        result.headingSpacing = spacing(headingSpacing)
        if let title {
            result.title = Title(font: font(title.font, fallback: .title3), color: title.color, spacing: spacing(title.spacing))
        }
        return result
    }
}
#endif
