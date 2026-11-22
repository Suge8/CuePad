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
    public var headingFont: CueFont
    public var codeFont: CueFont
    public var captionFont: CueFont
    public var fileGlyphSize: CGFloat
    public var markerColor: CueColor
    public var codeBackground: CueColor
    public var textColor: CueColor
    public var backgroundColor: CueColor
    public var variableColor: CueColor
    public var variableBackground: CueColor
    public var imagePlaceholderColor: CueColor
    public var horizontalInset: CGFloat
    public var maxTextWidth: CGFloat?
    public var verticalInset: CGFloat
    public var lineSpacing: CGFloat
    public var headingSpacing: CGFloat
    public var imageCornerRadius: CGFloat
    public var title: Title?

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
