import SwiftUI

/// 宽屏外框的尺寸（Mac 的窗口、iPad 的宽窗）：窗口最顶那一排（三栏的栏头）与会话条。全宽屏只有这一张表，组件只读这里的名字、不在组件里写数。
///
/// 密度：Mac 的外框是桌面工具栏的密度（指针点，ui-craft 的 compact～comfortable 之间），一排里只有一种控件高、一种行高；
/// 页里的内容（卡、对话）照 `Typography` 与 `Spacing` 的阅读密度。iPad 是触屏：同一张表，控件与行按手指 44。
///
/// 形状只有两种，按"有没有字"分，不混：
/// - 带字的是行（会话条宽版的项目、进展、会话、更早里的一行）：高 `row`，选中、悬停的底是行的形状（`RowStyle`），向两边让出 `RowMetrics.bleed`；
/// - 只有图标的是格（栏头的圆钮与图标钮、收起的图标条上的每一格、底部那一行的图标）：`control` 见方，底就是这一格（`RowStyle(cell: true)`），
///   玻璃上的是圆（`ControlButtonStyle(kind: .circular)`）。同一排的格、圆钮、玻璃列头都是这个高、同一条中线（窗口最顶那一排的中线就是红绿灯的中线）。
///
/// 被否决的：图标条上的格照行的形状铺满条宽（选中底成了 74×30 的扁条，图标钮该是正方，ui-craft）；按 30、36、44 三种高各配一种钮（同一排里一高一矮）。
enum Chrome {
    #if os(macOS)
    /// 窗口最顶那一排的高：系统按统一工具栏定，红绿灯在它的中线上；三栏的栏头都排在这一排。
    static let band: CGFloat = 52
    /// 会话条宽版一行的高。指针（Mac）：同访达侧栏的中号行。
    static let row: CGFloat = 32
    /// 收起的图标条：红绿灯两侧留白相等（灯左沿 19、三颗灯连同间隔 59.5、右边再留 19.5），条上每一格都在这条中轴上。
    static let strip: CGFloat = 98
    #else
    /// iPad 会话条顶上那一排（侧栏钮、搜索、Cue 钮）的高。
    static let band: CGFloat = 44
    /// 触控（iPad）：手指点得准的最小高（HIG 44）。接了触控板也是这一档——手指随时会点，iPadOS 自己的侧栏也不因指针改行高；
    /// 行与行之间、组与组之间同 Mac 的节奏（`cellGap`、`groupGap`），多出来的高只在行里。
    static let row: CGFloat = 44
    /// iPad 没有红绿灯，图标条只放得下一格加两边的纸。
    static let strip: CGFloat = 80
    #endif
    /// 一格的边长与一排控件的高：圆钮、图标钮、玻璃列头、图标条上的格都是它（同 `ControlMetrics.height`：Mac 36 同系统工具栏的玻璃钮，iPad 44）。
    static var control: CGFloat { ControlMetrics.height }
    /// 会话条宽版。
    static let rail: CGFloat = 256
    /// 宽版一行里的图标与字离行框（行框再往外是 `RowMetrics.bleed` 的底）。
    static let rowLead: CGFloat = 8
    /// 宽版一行行首的图标那一列（项目与进展的图标、会话的 Agent 标志、组头的记号都在这一列里居中）。
    static let icon: CGFloat = 20
    /// 组头（等你、推进中、更早）的高。
    static let groupHeader: CGFloat = 28
    /// 会话条里的一组（纸、行容器）离会话条边。
    static let gutter: CGFloat = 8
    /// 容器的内边：选中、悬停的底离容器边这么多（底的四角与容器同心，`Rows.swift`）。
    static let pad: CGFloat = 4
    /// 行在容器里让出多少：底比行宽出 `RowMetrics.bleed`，再离容器边 `pad`。
    static var rowInset: CGFloat { RowMetrics.bleed + pad }
    /// 一组里相邻两行、两格之间。
    static let cellGap: CGFloat = 4
    /// 组与组之间（顶上那一组、去处、等你、推进中、更早、底部那一行）。
    static let groupGap: CGFloat = 12
    /// 图标条上一组的宽：一格加两边的内边，在条里居中。
    static var stripGroup: CGFloat { control + 2 * pad }
}
