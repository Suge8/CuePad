import SwiftUI

/// 宽屏外框的尺寸（Mac 的窗口、iPad 的宽窗）：窗口最顶那一排（三栏的栏头）与会话条。全宽屏只有这一张表，组件只读这里的名字、不在组件里写数。
///
/// 密度：Mac 的外框是桌面工具栏的密度（指针点，ui-craft 的 compact～comfortable 之间），一排里只有一种控件高；
/// 页里的内容（卡、对话）照 `Typography` 与 `Spacing` 的阅读密度。iPad 是触屏：同一张表，控件按手指 44。
///
/// 会话条只有开着、藏起两态（同访达、备忘录、邮件）：开着宽 `rail`，藏起是整条不在（宽 0），没有中间的图标条。
/// 里面每一行是系统侧栏那种带字的行（`RowMetrics.height`，选中、悬停的底向两边让出 `RowMetrics.bleed`），行首图标那一列（`icon`）的左沿在 `lead`，
/// Mac 上正对红绿灯的左沿：窗口左边从上到下一条线。会话条贴着窗口的边，底色从窗口顶铺到底、不留离边的缝（macOS 27 的侧栏：WWDC26「Sidebars extend to the window's edges」，`WideRail` 头注释）。
/// 开合钮属于最顶那一排、钉在红绿灯右边（`toggle`），开着藏起都不动；藏起时主区栏头左边让出它（`headLead`）。iPad 顶上那一排同理（`RailTopTools`）。
///
/// 被否决的：收起成一条图标条（Mac 98、iPad 80）——一列没有名字的格要靠悬停才认得出，收起时开合钮又骑在图标条与主区的分界上；
/// 为了"开合格不挪"把每一行做成见方的格，行首那一列被钉在 98 的中轴上，字离窗边远、行像一格格的钮，不像一条栏。
enum Chrome {
    #if os(macOS)
    /// 窗口最顶那一排的高：系统按统一工具栏定，红绿灯在它的中线上；三栏的栏头都排在这一排。
    static let band: CGFloat = 52
    /// 会话条每一行行首图标那一列的左沿离窗口左边：红绿灯的左沿（实测 19.5，落在 4 点格上），窗口左边从红绿灯到最底下一行同一条线。
    static let lead: CGFloat = 20
    /// 开合钮（`SidebarToggle`，一颗 `ControlSize.compact` 的无底图标钮）的左沿离窗口左边：红绿灯的右沿（19.5 + 三颗连同间隔 59.5）再隔一档（`Spacing.item`），落在 4 点格上。
    static let toggle: CGFloat = 88
    /// 主区栏头左边让多少：会话条藏起时开合钮在主区那一段的最顶一排上，栏头让到它右沿再隔一档；开着时就是栏边（`Spacing.page`）。
    static func headLead(rail: CGFloat) -> CGFloat { rail > 0 ? Spacing.page : toggle + ControlSize.compact.height + Spacing.item }
    #else
    static let band: CGFloat = 44
    /// iPad 没有红绿灯：行首那一列离窗边同字离纸边。
    static let lead: CGFloat = Spacing.inset
    /// 主区栏头左边让多少：会话条藏起时顶上那一排三颗钮（侧栏钮、搜索、Cue 钮，`RailTopTools`）原地浮在主区那一段上，栏头让到它们右沿再隔一档。
    static func headLead(rail: CGFloat) -> CGFloat { rail > 0 ? Spacing.page : lead + 3 * (control + Spacing.item) }
    #endif
    /// 一排控件的高：圆钮、图标钮、玻璃列头（`ControlSize.regular`：Mac 36 同系统工具栏的玻璃钮，iPad 44）。
    static var control: CGFloat { ControlSize.regular.height }
    static let rail: CGFloat = 256
    /// 带字的行行首的图标那一列（会话条、`LinkRow`、技能与规则的行）。
    static let icon: CGFloat = 20
    static var row: CGFloat { RowMetrics.height }
    /// 等你组的会话行：名字下面一行写它要什么，比一行高一档；这一组每行同高，不随状态跳。
    static var tallRow: CGFloat { row + Spacing.group }
    /// 组头（等你、推进中）的高：字贴着下沿，离它那一组近、离上一组远。
    static let groupHeader: CGFloat = 28
    /// 会话行行首状态标的基准直径（`StateDot.size`，外框 1.8 倍，Mac 18 见方，放在 `icon` 那一列里）。
    static let railMark: CGFloat = 10
    /// 容器的内边：选中、悬停的底离容器边这么多（底的四角与容器同心，`Rows.swift`）。
    static let pad = Spacing.tight
    static let cellGap = Spacing.tight
    static let groupGap = Spacing.group
    /// 一组会话多到要滚时下沿淡出的那一截（ui-craft：可滚动的区域给出可见的提示）；不满一屏时不淡，最后一行不被盖。
    static let scrollFade = Spacing.block
    /// 会话条里一行的底（选中、悬停）左沿离窗口左边：行首那一列的左沿让出行底向两边伸出的那一截。
    static var gutter: CGFloat { lead - RowMetrics.bleed }
}
