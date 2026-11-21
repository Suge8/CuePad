import SwiftUI

enum Chrome {
    #if os(macOS)
    /// 窗口最顶那一排的高：系统按统一工具栏定，红绿灯在它的中线上；三栏的栏头都排在这一排。
    static let band: CGFloat = 52
    /// 会话条每一行行首图标那一列的左沿离窗口左边：红绿灯的左沿（实测 19.5，落在 4 点格上），窗口左边从红绿灯到最底下一行同一条线。
    static let lead: CGFloat = 20
    /// 开合钮（`SidebarToggle`，一颗 `ControlSize.compact` 的无底图标钮）的左沿离窗口左边：红绿灯的右沿（19.5 + 三颗连同间隔 59.5）再隔一档（`Spacing.item`），落在 4 点格上。
    static let toggle: CGFloat = 88
    static func headLead(rail: CGFloat) -> CGFloat { rail > 0 ? Spacing.page : toggle + ControlSize.compact.height + Spacing.item }
    #else
    static let band: CGFloat = 44
    static let lead: CGFloat = Spacing.inset
    static func headLead(rail: CGFloat) -> CGFloat { rail > 0 ? Spacing.page : lead + 2 * (control + Spacing.item) }
    #endif
    static var control: CGFloat { ControlSize.regular.height }
    static let rail: CGFloat = 256
    static let icon: CGFloat = 20
    static var row: CGFloat { RowMetrics.height }
    static var tallRow: CGFloat { row + Spacing.group }
    static let groupHeader: CGFloat = 28
    static let pad = Spacing.tight
    static let groupGap = Spacing.group
    static let scrollFade = Spacing.block
    static var gutter: CGFloat { lead - RowMetrics.bleed }
}
