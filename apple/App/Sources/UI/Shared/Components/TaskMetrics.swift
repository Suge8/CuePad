import SwiftUI

/// 任务区各块的尺寸：手机按动态字体与 44pt 点按，Mac 用小字。
enum TaskMetrics {
    #if os(iOS)
    nonisolated static let rowHeight: CGFloat = 44
    static let caption = Font.footnote
    static let chipTarget: CGFloat = 44
    static let titleRing: CGFloat = 24
    // 任务行（`TaskLine`）：上级正文字号、步骤小一档，圈也小一档
    static let lineFont = Font.body
    static let stepFont = Font.subheadline
    static let ring: CGFloat = 24
    static let stepRing: CGFloat = 16
    /// 圈那一列（也是它的点按区）多宽、与标题隔多少；行没有左右内边距（纸自己留了）。
    static let ringColumn: CGFloat = 44
    static let columnGap: CGFloat = 2
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let cardHeight: CGFloat = 60
    static let cardLead: CGFloat = 24
    static let cardGlyph: CGFloat = 13
    #else
    nonisolated static let rowHeight: CGFloat = 30
    static let caption = Typography.meta
    static let chipTarget: CGFloat = 24
    static let titleRing: CGFloat = 20
    // 任务行（`TaskLine`）：上级正文字号加一点字重、步骤小一档，圈也小一档
    static let lineFont = Typography.body.weight(.medium)
    static let stepFont = Typography.secondary
    static let ring: CGFloat = 17
    static let stepRing: CGFloat = 13
    /// 圈那一列多宽（新建行按它缩进，字与任务标题对齐）、与标题隔多少；悬停的淡底是行的底（`RowStyle`），向两边让出去。
    static let ringColumn: CGFloat = 18
    static let columnGap: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let cardHeight: CGFloat = 48
    static let cardLead: CGFloat = 16
    static let cardGlyph: CGFloat = 12
    #endif
}

/// 任务看板的卡（`boardCard`）：同一种卡一样高——待办、已完成是 `TaskMetrics.cardHeight`，推进中带线的卡是 `advancingHeight`；
/// 左右内边距 `cardPadding`、圆角 `cardRadius`；开头的记号占 `cardLead` 见方，看全部项目时标题前一个 `cardGlyph` 的项目小图形；
/// 卡离泳道边与卡与卡之间都是 `inset`（泳道圆角 = 卡圆角 + 它，同心）。
/// 推进中的卡从上往下：`titleTop`、标题一行 `titleRow`、`waveGap`、线（`WaveStrip.height`）、`waveBottom`。标题与线之间那一截两端同一个
/// `waveGap`：贴得近了，线读起来像标题的下划线或删除线。卡的高度由这几段加出来，不另写一个数。
enum BoardCardMetrics {
    static let inset: CGFloat = 8
    static let gap: CGFloat = 8
    static var radius: CGFloat { TaskMetrics.cardRadius }
    static let waveGap: CGFloat = 8
    /// 手机竖版看板（`boardRow`）：卡窄，内边距、记号与标题之间都收一点，标题小一档。
    static let rowPadding: CGFloat = 12
    static let rowGap: CGFloat = 6
    static let rowTitle = Font.subheadline.weight(.medium)
    #if os(macOS)
    static let titleTop: CGFloat = 8
    static let titleRow: CGFloat = 20
    static let waveBottom: CGFloat = 4
    #else
    static let titleTop: CGFloat = 10
    static let titleRow: CGFloat = 24
    static let waveBottom: CGFloat = 6
    #endif
    /// 线的上沿离卡顶多远。
    static var waveTop: CGFloat { titleTop + titleRow + waveGap }
    static var advancingHeight: CGFloat { waveTop + WaveStrip.height + waveBottom }
}
