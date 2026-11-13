import SwiftUI

enum TaskMetrics {
    /// 看板上的卡一律这个圆角（四列、摊开的那张、拖动时的轮廓）。
    static let cardRadius = Radius.sheet
    #if os(iOS)
    nonisolated static let rowHeight: CGFloat = 44
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    static let lineFont = Typography.body
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 24
    static let stepRing: CGFloat = 16
    /// 行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
    static let cardPadding = Spacing.group
    static let cardLead: CGFloat = 24
    static let cardGlyph: CGFloat = 13
    #else
    nonisolated static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    static let lineFont = Typography.body.weight(.medium)
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 17
    static let stepRing: CGFloat = 13
    /// 新建行按它缩进，字与任务标题对齐；悬停的淡底是行的底（`RowStyle`），向两边让出去。
    static let ringColumn: CGFloat = 18
    static let columnGap = Spacing.item
    static let cardPadding = Spacing.group
    static let cardLead: CGFloat = 16
    static let cardGlyph: CGFloat = 12
    #endif
}

enum BoardCardMetrics {
    static let inset = Spacing.item
    static let gap = Spacing.item
    /// 列与列之间不另留缝（`BoardWidths`）。否决过：列间再留 20——四列三道缝连同卡离列边共白占约 100，1280 宽时待办一行只剩三四个字。
    static var columnGap: CGFloat { 2 * inset }
    static let rowPadding = Spacing.group
    static let rowGap: CGFloat = 6
    static let rowTitle = Typography.secondary.weight(.medium)
    /// 列里的卡：字离上下边、标题与卡脚之间、卡脚的高（放得下线，也放得下"开始"的点按区）。
    #if os(macOS)
    static let pad = Spacing.group
    static let footGap = Spacing.glyph
    static let foot: CGFloat = 18
    static let vitals: CGFloat = 16
    #else
    static let pad = Spacing.group
    static let footGap = Spacing.glyph
    static let foot: CGFloat = 24
    static let vitals = foot
    #endif
    /// 卡脚里项目图形占的宽（名字放不下时只留它，`BoardFoot`）。
    static var footGlyph: CGFloat { TaskMetrics.cardGlyph + ProjectGlyph.margin }
    /// 待办、已完成的卡上下的边：比推进中的卡紧一档，一屏多放几条。
    static let compactPad: CGFloat = 10
    /// 标题至多几行（列里的卡上层就这么高）。
    nonisolated static func lines(_ typeSize: DynamicTypeSize) -> Int { typeSize.isAccessibilitySize ? 3 : 2 }
    /// 卡脚里项目名最宽：约七个汉字，再长就截，给线与读数留地方。
    static let tagMax: CGFloat = 104
    /// 手机的行里的卡。
    static let titleRow: CGFloat = 24
    /// 推进中的行下沿给读数留的高。
    static let rowFact: CGFloat = 18
}
