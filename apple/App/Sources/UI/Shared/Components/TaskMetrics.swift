import SwiftUI

/// 任务区各块的尺寸：手机按动态字体与 44pt 点按，Mac 用小字。
enum TaskMetrics {
    #if os(iOS)
    nonisolated static let rowHeight: CGFloat = 44
    static let caption = Font.footnote
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    // 任务行（`TaskLine`）：上级正文字号、子任务小一档，圈也小一档
    static let lineFont = Font.body
    static let stepFont = Font.subheadline
    static let ring: CGFloat = 24
    static let stepRing: CGFloat = 16
    /// 圈那一列（也是它的点按区）多宽、与标题隔多少；行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
    static let cardPadding: CGFloat = 14
    static let cardRadius = Radius.card
    static let cardLead: CGFloat = 24
    static let cardGlyph: CGFloat = 13
    #else
    nonisolated static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    // 任务行（`TaskLine`）：上级正文字号加一点字重、子任务小一档，圈也小一档
    static let lineFont = Typography.body.weight(.medium)
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 17
    static let stepRing: CGFloat = 13
    /// 圈那一列多宽（新建行按它缩进，字与任务标题对齐）、与标题隔多少；悬停的淡底是行的底（`RowStyle`），向两边让出去。
    static let ringColumn: CGFloat = 18
    static let columnGap: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardRadius = Radius.block
    static let cardLead: CGFloat = 16
    static let cardGlyph: CGFloat = 12
    #endif
}

/// 任务看板的卡（`boardCard`）：左右内边距 `cardPadding`、圆角 `cardRadius`；开头的记号占 `cardLead` 见方，看全部项目时标题前一个 `cardGlyph` 的项目小图形；
/// 卡离列边与卡与卡之间都是 `inset`（列的托盘与拖入底是 `Radius.sheet`，与卡近似同心）。
/// 卡的高度由几段加出来（`BoardCardLayout`），不另写一个数：列里的卡是上下留白（重的列 `titlePadding`、轻的列 `lightPadding`）、标题（按 `title` 留足行数，至少 `titleRow`）；
/// 推进中的卡是 `titleTop`、标题那一带、`waveGap`、线（`WaveStrip.height`）、`waveBottom`，与等你的卡同高。
/// 标题与线之间那一截（Mac 6、手机 8）不能再窄：再贴近，线读起来像标题的下划线或删除线。手机竖版看板里卡铺满行给的格（`BoardRowLane`）。
enum BoardCardMetrics {
    static let inset: CGFloat = 8
    static let gap: CGFloat = 8
    /// 手机竖版看板（`boardRow`）：卡窄，内边距、记号与标题之间都收一点，标题小一档。
    static let rowPadding: CGFloat = 12
    static let rowGap: CGFloat = 6
    static let rowTitle = Font.subheadline.weight(.medium)
    #if os(macOS)
    static let titlePadding: CGFloat = 14
    static let lightPadding: CGFloat = 7
    static let titleTop: CGFloat = 6
    static let titleRow: CGFloat = 20
    static let waveBottom: CGFloat = 4
    #else
    static let titlePadding: CGFloat = 18
    static let lightPadding: CGFloat = 10
    static let titleTop: CGFloat = 10
    static let titleRow: CGFloat = 24
    static let waveBottom: CGFloat = 6
    #endif
    /// 推进中的卡与别的列的卡同高：线占掉的那一截从上下两份 `titlePadding` 里出。
    static var waveGap: CGFloat { 2 * titlePadding - titleTop - WaveStrip.height - waveBottom }

    /// 卡标题留几行、那一截多高、上下留多少（三端的列与手机的行同一条，所在的列或行按卡宽与字号算一次交给卡，`boardTitle`）：
    /// 卡里放字那一截（去掉左右内边距，连开头记号与项目小图形）宽得下 `oneLine` 个字排一行，否则两行——Mac 常用窗口与 iPad 横屏的列里
    /// 一行写得下大多数标题，iPad 竖屏、窄窗口、iPhone 横屏的列里写不下；辅助字号下再多一行。高按行数留足（只有一行字的卡也一样高，
    /// 字在里面竖直居中）。轻的两列（`TaskBoard.Column.light`）是矮卡：宽得下 `lightLine` 个字就排一行，上下只留 `lightPadding`。
    /// 手机的行里卡总窄（`cardWidth` 给 nil）：两行，卡铺满行给的格，不另留高。
    static func title(_ column: TaskBoard.Column, cardWidth: CGFloat?, typeSize: DynamicTypeSize) -> BoardTitle {
        let more = typeSize.isAccessibilitySize ? 1 : 0
        guard let cardWidth else { return BoardTitle(lines: 2 + more) }
        let font = titleFont(typeSize)
        let wide = cardWidth - 2 * TaskMetrics.cardPadding >= (column.light ? lightLine : oneLine) * font.pointSize
        let lines = (wide ? 1 : 2) + more
        return BoardTitle(
            lines: lines, height: max(titleRow, (font.lineHeight * CGFloat(lines)).rounded(.up)), padding: column.light ? lightPadding : titlePadding)
    }

    private static let oneLine: CGFloat = 14
    /// 开头的圈与项目小图形约占三个字宽：一行放得下八个字的标题。
    private static let lightLine: CGFloat = 11

    /// 列里卡标题的字（`TaskMetrics.lineFont`）：中文字宽等于字号。
    private static func titleFont(_ typeSize: DynamicTypeSize) -> (pointSize: CGFloat, lineHeight: CGFloat) {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: Typography.bodySize, weight: .medium)
        return (font.pointSize, NSLayoutManager().defaultLineHeight(for: font))
        #else
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
        return (font.pointSize, font.lineHeight)
        #endif
    }
}

/// 卡标题留几行、那一截至少多高、上下留多少（`BoardCardMetrics.title`；手机的行里卡铺满格，不另留高与上下）。
struct BoardTitle: Equatable {
    var lines = 1
    var height: CGFloat = 0
    var padding: CGFloat = 0
}
