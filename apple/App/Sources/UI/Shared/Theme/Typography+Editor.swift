import CueEditor
import SwiftUI

extension Typography {
    #if os(macOS)
    static let readingFont = NSFont.systemFont(ofSize: readingSize)
    static let editorHeadingFont = NSFont.systemFont(ofSize: readingHeadingSize, weight: .semibold)
    static let editorCodeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    static let editorCaptionFont = NSFont.systemFont(ofSize: 12)
    static let taskBodyFont = NSFont.systemFont(ofSize: bodySize)
    static let taskTitleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let taskBody = body
    static let readingParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = readingLineSpacing
        return paragraph
    }()
    #else
    /// Kit 接收默认档位的设计值，由当前视图的 trait 缩放一次；不能把已缩放的 preferredFont 再缩一遍。
    static var readingFont: UIFont { baseFont(.body) }
    static var editorHeadingFont: UIFont { baseFont(.title3, weight: .semibold) }
    static var editorCodeFont: UIFont { baseFont(.footnote, monospaced: true) }
    static var editorCaptionFont: UIFont { baseFont(.caption1) }
    static var taskBodyFont: UIFont { baseFont(.callout) }
    static var taskTitleFont: UIFont { baseFont(.title3, weight: .semibold) }
    static let taskBody = Font.callout

    private static func baseFont(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil, monospaced: Bool = false) -> UIFont {
        var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        if monospaced { descriptor = descriptor.withDesign(.monospaced)! }
        if let weight { descriptor = descriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]) }
        return UIFont(descriptor: descriptor, size: 0)
    }

    static func readingFont(for traits: UITraitCollection) -> UIFont {
        .preferredFont(forTextStyle: .body, compatibleWith: traits)
    }

    static func readingParagraph(for traits: UITraitCollection) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = UIFontMetrics(forTextStyle: .body).scaledValue(for: readingLineSpacing, compatibleWith: traits)
        return paragraph
    }
    #endif
}
