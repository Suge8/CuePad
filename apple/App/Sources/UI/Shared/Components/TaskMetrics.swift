import SwiftUI

/// 任务区各块的尺寸：手机按动态字体与 44pt 点按，Mac 用小字。
enum TaskMetrics {
    #if os(iOS)
    nonisolated static let rowHeight: CGFloat = 44
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    // 任务行（`TaskLine`）：上级正文字号、子任务小一档，圈也小一档
    static let lineFont = Typography.body
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 24
    static let stepRing: CGFloat = 16
    /// 圈那一列（也是它的点按区）多宽、与标题隔多少；行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
    static let cardPadding = Spacing.group
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
    static let columnGap = Spacing.item
    static let cardPadding = Spacing.group
    static let cardRadius = Radius.block
    static let cardLead: CGFloat = 16
    static let cardGlyph: CGFloat = 12
    #endif
}

/// 任务看板的卡（`boardCard`）：左右内边距 `cardPadding`、圆角 `cardRadius`；开头的记号占 `cardLead` 见方，看全部项目时标题前一个 `cardGlyph` 的项目小图形；
/// 卡离列边与卡与卡之间都是 `inset`（列的托盘与拖入底是 `Radius.sheet`，与卡近似同心）。
/// 卡的高度由几段加出来（`BoardCardLayout`），不另写一个数：列里的卡是上下留白（重的列 `titlePadding`、轻的列 `lightPadding`）、标题（实际排了几行，至多 `title` 给的行数，至少 `titleRow`）；
/// 推进中的卡是 `titleTop`、标题那一带、`waveGap`、线（`WaveStrip.height`）、`waveBottom`，与等你的卡同高。
/// 标题与线之间那一截（Mac 6、手机 8）不能再窄：再贴近，线读起来像标题的下划线或删除线。手机竖版看板里卡铺满行给的格（`BoardRowLane`）。
enum BoardCardMetrics {
    static let inset = Spacing.item
    static let gap = Spacing.item
    /// 相邻两列的卡（与列头玻璃）横着隔多少：就是两列各自的 `inset`，列与列之间不另留缝（`BoardWidths`）。
    /// 否决过：列间再留 20——四列三道缝连同卡离列边共白占约 100，1280 宽时待办一行只剩三四个字。
    static var columnGap: CGFloat { 2 * inset }
    /// 卡里开头记号、项目小图形、标题、尾巴之间（`BoardCardLayout`）。
    static let leadGap = Spacing.item
    /// 推进中卡下沿那条线最窄多宽才画（`BoardLineRow`）：过去两颗点与现在一截波读得出来；再窄整条不画，只留读数。
    nonisolated static let lineMin: CGFloat = 40
    /// 手机竖版看板（`boardRow`）：卡窄，内边距、记号与标题之间都收一点，标题小一档。
    static let rowPadding = Spacing.group
    static let rowGap: CGFloat = 6
    static let rowTitle = Typography.secondary.weight(.medium)
    #if os(macOS)
    static let titlePadding = Spacing.group
    static let lightPadding: CGFloat = 7
    static let titleTop: CGFloat = 6
    static let titleRow: CGFloat = 20
    static let waveBottom: CGFloat = 4
    #else
    static let titlePadding = Spacing.block
    static let lightPadding = Spacing.item
    static let titleTop = Spacing.item
    static let titleRow: CGFloat = 24
    static let waveBottom: CGFloat = 6
    #endif
    /// 推进中的卡与别的列的卡同高：线占掉的那一截从上下两份 `titlePadding` 里出。
    static var waveGap: CGFloat { 2 * titlePadding - titleTop - WaveStrip.height - waveBottom }

    /// 卡标题至多几行、上下留多少（三端的列与手机的行同一条，所在的列或行按卡宽与字号算一次交给卡，`boardTitle`）：
    /// 按标题那一截一行放得下几个字定（卡宽去掉左右内边距、开头的圈与项目小图形连同它们与标题之间的缝，`lead`）。
    /// 带着项目小图形一行放不下 `glyphLine` 个字时项目小图形让位（`BoardTitle.glyph`），只留状态圈：项目色在会话条、项目页与悬停提示里都有，窄卡上字要紧。
    /// 列式卡至少三行，一行放不下 `twoLine` 个字时辅助字号再多一行。标题多是十到十二个字（大库里九到二十二个），
    /// 一行八个字、两行一行五个字都会截成"改走统…"。行数是上限、不预留：一行写得下的卡就一行高（`BoardCardLayout`），不在标题下空一块；
    /// 所以上限不给一行——宽列里二十来个字的标题给一行只会截断（1512 宽等你列的"README 截图换成 Swif…"），不省地方。
    /// 轻的两列（`TaskBoard.Column.light`）是矮卡：上下只留 `lightPadding`。
    /// 手机的行里卡总窄（`cardWidth` 给 nil）：两行，卡铺满行给的格，不另留高。
    static func title(_ column: TaskBoard.Column, cardWidth: CGFloat?, typeSize: DynamicTypeSize) -> BoardTitle {
        let more = typeSize.isAccessibilitySize ? 1 : 0
        guard let cardWidth else { return BoardTitle(lines: 2 + more) }
        let room = cardWidth - 2 * TaskMetrics.cardPadding, size = titleSize(typeSize)
        let glyph = (room - lead(glyph: true)) / size >= glyphLine
        let chars = (room - lead(glyph: glyph)) / size
        let lines = max(3, (chars >= twoLine ? 2 : 3) + more)
        return BoardTitle(lines: lines, padding: column.light ? lightPadding : titlePadding, glyph: glyph)
    }

    private static let twoLine: CGFloat = 7
    /// 带着项目小图形一行至少放得下几个字：再少就让它让位。
    private static let glyphLine: CGFloat = 6
    /// 圈、项目小图形与它们之间、到标题、标题到右边的缝。
    private static func lead(glyph: Bool) -> CGFloat {
        TaskMetrics.cardLead + leadGap * 2 + (glyph ? TaskMetrics.cardGlyph + leadGap : 0)
    }

    /// 列里卡标题的字号（`TaskMetrics.lineFont`）：中文字宽等于字号。
    private static func titleSize(_ typeSize: DynamicTypeSize) -> CGFloat {
        #if os(macOS)
        Typography.bodySize
        #else
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))).pointSize
        #endif
    }
}

/// 卡标题至多几行、上下留多少（`BoardCardMetrics.title`；手机的行里卡铺满格，不另留上下）。
struct BoardTitle: Equatable {
    var lines = 1
    var padding: CGFloat = 0
    /// 卡标题前画项目小图形（看全部项目时）；窄卡上让位（`BoardCardMetrics.title`）。
    var glyph = true
}
