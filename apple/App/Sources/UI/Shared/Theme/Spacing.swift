import SwiftUI

/// 间距的唯一来源，两端同名、值按平台（Mac 指针密度，手机与 iPad 触屏），都在 4 点格上；Theme 以外 `padding`、`spacing:`、`EdgeInsets` 不写数（`lint.sh` 查）。
/// 每档的两端值与用途、不在格上的数怎么就近落档、哪些算组件几何不进这里，都在 docs/ui.md「间距」；窗口外框的数在 `Chrome`，它的几项读这里。
///
/// 被否决的：给 6 另立一档「一项里相邻两块」（标题与说明、气泡与它带的图）——6 不在格上，同一件事有人写 4 有人写 8 正是因为没有档；
/// 这类按「组件内部往下」落到 `tight`，相邻的行与钮落到 `item`。
nonisolated enum Spacing {
    /// 紧贴：同一项里上下几行字（名字与它下面那行、标题与它的副题）、记号贴字（字后面的箭头）、列表里相邻两行之间那道缝。
    static let hair: CGFloat = 2
    /// 一块里标题与它下面的说明、小组头紧贴它下面那一组；控件里图标与字之外的紧挨（数与单位、两颗小钮之间）、小胶囊上下的边。
    static let tight: CGFloat = 4
    /// 图标、记号与旁边的字（横排或竖排都是），含名字后面跟的计数与"/"这类分隔。
    static let glyph: CGFloat = 6
    /// 一行里相邻几样、一组里相邻两行与两块、卡与卡、一排里相邻两颗钮与胶囊；栏头里相邻两颗钮、两块玻璃（不共用系统玻璃底的项，系统不给留空）。
    static let item: CGFloat = 8
    /// 一块里的几组之间、页级分组标题到内容、气泡里字离上下边。
    static let group: CGFloat = 12
    /// 一块与一块之间（几个账号、几张纸、几段说明、对话里两条之间）：比组里松一档、比页内分组紧。
    static let block: CGFloat = 16
    /// 面板与清单里几大块之间（Cue 面板的三块、记忆清单的几组）：面板比页窄，比页内分组（`section`）紧一档，两端同值。
    static let part: CGFloat = 24
    /// 大张纸的内边（空态那张纸、宽 iPad 上居中的编辑纸）：圆角 `Radius.sheet` 那一档，字离纸边约同圆角，两端同值。
    static let sheet: CGFloat = 24
    #if os(macOS)
    /// 纸、卡、行里的字离左右边。
    static let inset: CGFloat = 12
    /// 浮层、面板与浮在页上的条的内边，也是页上大块纸（项目页的任务纸）的左右内边。
    static let panel: CGFloat = 20
    /// 一栏的边：页面内容的左右边距，也是这一栏栏头里第一样东西与最后一颗钮离栏边（栏头与下面的内容同一条左边、同一条右边）。
    /// 看板的卡、项目页的纸、对话的列（`SessionChat`、`CuePage` 的 inset）都从这里起。
    static let page: CGFloat = 24
    /// 页内分组之间；滚动区到底多留的一截（最后一项不贴着栏底）。
    static let section: CGFloat = 32
    /// 页里只有一句话或一张空态（正在读、还没有）时它离上面的东西：落在页的上三分之一，不贴着栏头。
    static let vacant: CGFloat = 120
    /// 页面内容离工具栏下沿（只 Mac：手机的页顶那一排自己让出内容，`floatingHeader`）。
    static let pageTop: CGFloat = 24
    /// 对话的阅读栏最宽（会话、Cue、设置这类读的一列）：长回答一行不至于太长，气泡也不挤；两侧仍离栏边 `page`。
    static let reading: CGFloat = 760
    /// 浮在对话底上的那一块（回复框、对 Cue 说，连同叠在上面的卡）离对话区底边，各页只经 `FloatingReply` 用它：
    /// Mac 是栏底，与主区底部那一条同高；手机与 iPad 是安全区底边，键盘弹出时是键盘顶，那里已有系统留的边、只隔一条缝。
    static let replyBottom: CGFloat = 16
    #else
    static let inset: CGFloat = 16
    static let panel: CGFloat = 16
    static let page: CGFloat = 16
    static let section: CGFloat = 24
    static let vacant: CGFloat = 40
    static let reading: CGFloat = 640
    static let replyBottom: CGFloat = 8
    #endif
}
