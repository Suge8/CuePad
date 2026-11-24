import SwiftUI

enum TaskMetrics {
    #if os(iOS)
    nonisolated static let rowHeight: CGFloat = 44
    static let caption = Typography.meta
    static let captionBold = Typography.metaBold
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    static let lineFont = Typography.body
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 24
    static let stepRing: CGFloat = 16
    static let ringColumn: CGFloat = 44
    static let columnGap = Spacing.hair
    static let cardPadding = Spacing.group
    static let cardGlyph: CGFloat = 13
    static let rowGap: CGFloat = 0
    static let ringInset = (ringColumn - ring) / 2
    #else
    nonisolated static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let captionBold = Typography.metaBold
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    static let lineFont = Typography.bodyBold
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 17
    static let stepRing: CGFloat = 13
    static let ringColumn: CGFloat = 18
    static let columnGap = Spacing.item
    static let cardPadding = Spacing.group
    static let cardGlyph: CGFloat = 12
    static let rowGap = (RowMetrics.height - rowHeight) / 2
    static let ringInset: CGFloat = 0
    #endif
}

enum BoardCardMetrics {
    static let inset = Spacing.item
    static let gap = Spacing.item
    static var columnGap: CGFloat { 2 * inset }
    #if os(macOS)
    static let pad = Spacing.group
    static let footGap = Spacing.glyph
    static let foot: CGFloat = 18
    static let vitals: CGFloat = 16
    #else
    static let pad = Spacing.group
    static let footGap = Spacing.glyph
    static let foot: CGFloat = 24
    static let vitals: CGFloat = 18
    #endif
    static var footGlyph: CGFloat { TaskMetrics.cardGlyph + ProjectGlyph.margin }
    static let compactPad: CGFloat = 10
    nonisolated static func lines(_ typeSize: DynamicTypeSize) -> Int { typeSize.isAccessibilitySize ? 3 : 2 }
    nonisolated static func rowLines(_ typeSize: DynamicTypeSize) -> Int { typeSize.isAccessibilitySize ? 2 : 1 }
    static let tagMax: CGFloat = 104
}
