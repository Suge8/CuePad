import SwiftUI

/// 宽屏外框的尺寸（Mac 的窗口、iPad 的宽窗）：窗口最顶那一排（三栏的栏头）与会话条。全宽屏只有这一张表，组件只读这里的名字、不在组件里写数。
///
/// 密度：Mac 的外框是桌面工具栏的密度（指针点，ui-craft 的 compact～comfortable 之间），一排里只有一种控件高；
/// 页里的内容（卡、对话）照 `Typography` 与 `Spacing` 的阅读密度。iPad 是触屏：同一张表，控件按手指 44。
///
/// 会话条只有一套排法（`WideRail`）：每一组的左沿钉在 `edge`，组里每一行行首是一格见方（`control`）的那一列，正在条的中轴上（Mac 对着中间那颗红绿灯）。
/// 收起（`strip`）与展开（`rail`）是同一棵视图树，只差会话条多宽：组的右沿跟着宽走，格与行的位置一点不动，展开只是把行首那一列右边的名字露出来。
/// 选中、悬停的底就是这一行的框（`RowStyle(cell: true)`）：收起时一行就是一格，底也就是一格见方。
///
/// 被否决的：收起与展开各一套排法（宽版是带字的行、图标条是一列格）——开合时每一格都换位置，眼睛要重新找；图标条上的格照行的形状铺满条宽（图标钮该是正方，ui-craft）。
enum Chrome {
    #if os(macOS)
    /// 窗口最顶那一排的高：系统按统一工具栏定，红绿灯在它的中线上；三栏的栏头都排在这一排。
    static let band: CGFloat = 52
    /// 收起的会话条：红绿灯两侧留白相等（灯左沿 19、三颗灯连同间隔 59.5、右边再留 19.5），会话条的中轴就是中间那颗灯。
    static let strip: CGFloat = 98
    #else
    /// iPad 窗口最顶那一排的高（主区的栏头）。
    static let band: CGFloat = 44
    /// iPad 没有红绿灯，收起的会话条只放得下一格加两边的纸。
    static let strip: CGFloat = 80
    #endif
    /// 一格的边长、会话条上一行的高与一排控件的高：圆钮、图标钮、玻璃列头、会话条上的每一行都是它（`ControlSize.regular`：Mac 36 同系统工具栏的玻璃钮，iPad 44）。
    static var control: CGFloat { ControlSize.regular.height }
    /// 展开的会话条。
    static let rail: CGFloat = 256
    /// 带字的行行首的图标那一列（`LinkRow`、技能与规则的行）。
    static let icon: CGFloat = 20
    /// 组头（等你、推进中）的高。
    static let groupHeader: CGFloat = 28
    /// 容器的内边：选中、悬停的底离容器边这么多（底的四角与容器同心，`Rows.swift`）。
    static let pad = Spacing.tight
    /// 一组里相邻两行之间。
    static let cellGap = Spacing.tight
    /// 组与组之间（顶上那一组、去处、等你、推进中、更早、底部那一行）。
    static let groupGap = Spacing.group
    /// 收起时一组的宽：一格加两边的内边。
    static var stripGroup: CGFloat { control + 2 * pad }
    /// 会话条上每一组的左沿离会话条边：收起时一组正在条的中轴上，展开时左沿不动、右沿离边同样远。
    static var edge: CGFloat { (strip - stripGroup) / 2 }

    // MARK: 会话条重设计原型（`-CuePadRailProto A|B|C`，`RailProto`）

    /// 收起时并排两格（顶上侧栏钮与搜索、底部技能与规则与设置）的左格离条边：两格连同中缝正在中轴上。
    static var pairEdge: CGFloat { (strip - 2 * control - cellGap) / 2 }
    /// A：行首状态标的基准直径（`PiStateDot.size`，外框 1.8 倍，Mac 约 18 见方）。
    static let railMark: CGFloat = 10
    /// B：带状态环的头像的直径（环外沿），一格里四边各让一档，外扩的波纹才放得下。
    static var avatar: CGFloat { control - Spacing.item }
    /// B 的会话行、C 要你管的会话行：名字下面多一行，比一格高一档。
    static var tallRow: CGFloat { control + Spacing.item }
    /// C 歇着的会话行：轻，同卡里钮的高。
    static var lightRow: CGFloat { ControlSize.compact.height }
    /// C 在跑的行行尾那一截心电线（`BoardLine` 的现在）。
    static let trace: CGFloat = 32
}
