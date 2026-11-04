import SwiftUI

/// 间距的唯一来源，两端同名、值按平台（Mac 指针密度，手机与 iPad 触屏），都在 4 点的格上。按"这一段空隔开的是什么"取，不按好看另配一个数；
/// 窗口外框（栏头那一排与会话条）的数在 `Chrome`，它的几项读这里。控件自己的高与字离两头在 `ControlSize`。
///
/// 10、14、18 这类不在格上的数不另立档，按角色就近：组件内部（控件、行、卡、气泡里）往下取 8／12／16，组与组之间往上取 12／16／24。
/// 2 与 6 只给光学校准（记号贴字、图标与旁边的字），不当一般间距用。组件自己的几何（面板宽、缩略图边长、列宽）是组件里的具名常量，不进这里。
nonisolated enum Spacing {
    /// 光学校准：记号贴字、一行里几乎挨着的两样。
    static let hair: CGFloat = 2
    /// 控件里图标与字之外的紧挨（数与单位、两颗小钮之间）。
    static let tight: CGFloat = 4
    /// 图标与旁边的字。
    static let glyph: CGFloat = 6
    /// 一行里相邻几样、一组里相邻两行、卡与卡；栏头里相邻两颗钮、两块玻璃（不共用系统玻璃底的项，系统不给留空）。
    static let item: CGFloat = 8
    /// 一块里的几组之间、分组标题到内容。
    static let group: CGFloat = 12
    /// 一块与一块之间（几个账号、几张纸、几段说明）：比组里松一档、比页内分组紧。
    static let block: CGFloat = 16
    #if os(macOS)
    /// 纸、卡、气泡、行里的字离左右边。
    static let inset: CGFloat = 12
    /// 浮层与面板的内边。
    static let panel: CGFloat = 20
    /// 一栏的边：页面内容的左右边距，也是这一栏栏头里第一样东西与最后一颗钮离栏边（栏头与下面的内容同一条左边、同一条右边）。
    /// 看板的卡、项目页的纸、对话的列（`SessionChat`、`CuePage` 的 inset）都从这里起。
    static let page: CGFloat = 24
    /// 页内分组之间。
    static let section: CGFloat = 32
    /// 页面内容离工具栏下沿（只 Mac：手机的页顶那一排自己让出内容，`floatingHeader`）。
    static let pageTop: CGFloat = 24
    /// 回复框（会话的、对 Cue 说）与它上面的拍板卡离栏底。
    static let replyBottom: CGFloat = 16
    /// 对话的阅读栏最宽（会话、Cue、设置这类读的一列）：长回答一行不至于太长，气泡也不挤；两侧仍离栏边 `page`。
    static let reading: CGFloat = 760
    #else
    static let inset: CGFloat = 16
    static let panel: CGFloat = 16
    static let page: CGFloat = 16
    static let section: CGFloat = 24
    static let reading: CGFloat = 640
    #endif
}
