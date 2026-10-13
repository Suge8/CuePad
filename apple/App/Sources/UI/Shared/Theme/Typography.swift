import SwiftUI

/// 字号与行距的唯一来源，共享组件里的平台差异只在这里：iOS 用系统文字样式、跟随动态字体；
/// Mac 没有动态字体，系统文字样式偏小（正文 13、脚注与说明 10），苹方在这个字号下读着吃力，所以 Mac 按角色给固定字号，
/// 比系统样式高一档，层级之间至少差 1pt、靠字重与墨色深浅再拉开。
enum Typography {
    #if os(macOS)
    /// 正文：卡片摘要、列表的主文字、输入框（AppKit 的输入框按 `bodySize` 取同一号）。
    static let bodySize: CGFloat = 14
    static let body = Font.system(size: bodySize)
    /// 强调的正文：卡片标题、列表行的名字。
    static let bodyStrong = Font.system(size: 15, weight: .semibold)
    /// 次要：说明、一行里跟在标题后的摘要、空态的说明。
    static let secondary = Font.system(size: 13)
    /// 元信息：时间、计数、路径、标记。
    static let meta = Font.system(size: 12)
    /// 小节标签（任务与 Agent 栏的"任务""Agent"、提示词、步骤）：小号加粗、次要墨色。
    static let label = Font.system(size: 12, weight: .semibold)
    /// 最小的字：折起的计数、工具注脚这类附注（iOS 比元信息小一档，Mac 不再往下小）；caption2 是展开箭头这类更小的符号。
    static let caption = Font.system(size: 12)
    static let caption2 = Font.system(size: 11)
    /// 阅读：会话里的回答与你的话（Markdown 正文、列表、引用、气泡），比界面正文大一号；标题与代码同属这一列。
    static let reading = Font.system(size: 15)
    static let readingHeading = Font.system(size: 18, weight: .semibold)
    static let code = Font.system(size: 13).monospaced()
    /// 注脚里的等宽字（一轮回答的工具清单）：比代码块小一档，是回答的注脚、不跟回答抢。
    static let codeNote = Font.system(size: 12).monospaced()
    /// 回答正文里的行内代码：约是阅读正文的 0.9 倍（等宽字同字号下比中文显得大）。
    static let inlineCode = Font.system(size: 13.5).monospaced()
    /// 阅读列的行距：长回答是会话页的主角，行高放到约 1.6 倍。
    static let readingLineSpacing: CGFloat = 6
    /// 醒目的一句（等你确认的问题）。
    static let title = Font.system(size: 17, weight: .medium)
    /// 页内分组标题（资料、最近、更早、现在、历史）与它旁边的计数。
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let sectionCount = Font.system(size: 13).monospacedDigit()
    /// 纸页里的标题（任务名）。
    static let heading = Font.system(size: 22, weight: .semibold)
    /// ⌘K 搜索框的输入与右侧预览的标题：浮层里最大的两行字。
    static let searchField = Font.system(size: 18)
    static let previewTitle = Font.system(size: 17, weight: .bold)
    /// 键帽（快捷键提示）。
    static let keycap = Font.system(size: 11, weight: .medium, design: .rounded)
    /// 页标题（项目名、归档、回收站）与其下一句介绍。
    static let pageTitle = Font.system(size: 28, weight: .bold)
    static let lead = Font.system(size: 16)
    /// 空态的标题。
    static let emptyTitle = Font.system(size: 17, weight: .semibold)
    /// 工具栏：按钮上的字（收起、项目切换），会话页的标题与其下一行。
    static let toolbarLabel = Font.system(size: 13, weight: .medium)
    static let toolbarTitle = Font.system(size: 15, weight: .semibold)
    static let toolbarSubtitle = Font.system(size: 12)
    /// 侧栏：行、行下的一句（项目的"此刻"）、分组标题。
    static let sidebarRow = Font.system(size: 14)
    static let sidebarDetail = Font.system(size: 12)
    static let sidebarHeader = Font.system(size: 12, weight: .semibold)
    /// 多行正文的行距：苹方的默认行高偏紧，加上这些约是 1.5 倍行高。
    static let lineSpacing: CGFloat = 4
    #else
    static let body = Font.body
    static let bodyStrong = Font.headline
    static let secondary = Font.subheadline
    static let meta = Font.footnote
    static let label = Font.caption.weight(.semibold)
    static let caption = Font.caption
    static let caption2 = Font.caption2
    static let reading = Font.body
    static let readingHeading = Font.title3.weight(.semibold)
    static let code = Font.footnote.monospaced()
    static let codeNote = Font.caption.monospaced()
    static let inlineCode = Font.callout.monospaced()
    static let readingLineSpacing: CGFloat = 3
    static let title = Font.title3.weight(.medium)
    static let heading = Font.title3.weight(.semibold)
    static let emptyTitle = Font.title3.weight(.semibold)
    #endif
}

#if os(macOS)
/// Mac 的间距：页面边距、分组间距、工具栏与侧栏的行高。
enum Spacing {
    /// 页面内容的左右边距。
    static let page: CGFloat = 36
    /// 页面内容离工具栏下沿。
    static let pageTop: CGFloat = 24
    /// 页内分组之间、分组标题到内容。
    static let section: CGFloat = 32
    static let sectionTitle: CGFloat = 12
    /// 工具栏里自绘控件的高度：与系统工具栏的圆钮同高。
    static let toolbarControl: CGFloat = 36
    /// 侧栏行高：单行与项目的两行（名称与"此刻"）。
    static let sidebarRow: CGFloat = 32
    static let sidebarProjectRow: CGFloat = 46
    /// 侧栏行首的图标列（项目图标、会话状态标在里面居中）。
    static let sidebarIcon: CGFloat = 20
}
#endif
