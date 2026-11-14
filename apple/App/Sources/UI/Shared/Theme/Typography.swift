import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 字号与行距的唯一来源（图标的尺寸在 `Glyph`），Theme 以外不写字号的数（`lint.sh` 查）。共享组件里的平台差异只在这里：iOS 用系统文字样式、跟随动态字体；
/// Mac 没有动态字体，系统文字样式偏小（正文 13、脚注与说明 10），苹方在这个字号下读着吃力，所以 Mac 按角色给固定字号，
/// 比系统样式高一档，层级之间至少差 1pt、靠字重与墨色深浅再拉开。
enum Typography {
    #if os(macOS)
    /// 正文：卡片摘要、列表的主文字（输入框与气泡同一号，是阅读的 `readingSize`）。
    nonisolated static let bodySize: CGFloat = 14
    static let body = Font.system(size: bodySize)
    /// 强调的正文：卡片标题、列表行的名字。
    static let bodyStrong = Font.system(size: 15, weight: .semibold)
    /// 次要：说明、一行里跟在标题后的摘要、空态的说明。
    static let secondary = Font.system(size: 13)
    /// 元信息：时间、计数、路径、标记。
    static let meta = Font.system(size: 12)
    /// 小节标签（任务与 Agent 栏的"任务""Agent"、子任务）：小号加粗、次要墨色。
    static let label = Font.system(size: 12, weight: .semibold)
    /// 最小的字：折起的计数、对话里的旁注（`NoteLine`）这类附注（iOS 比元信息小一档，Mac 不再往下小）；caption2 是展开箭头这类更小的符号。
    static let caption = Font.system(size: 12)
    static let caption2 = Font.system(size: 11)
    /// 阅读：会话里的回答与你的话（Markdown 正文、列表、引用、气泡），比界面正文大两号：对话是 Cue 页与会话页的主角；标题与代码同属这一列。
    nonisolated static let readingSize: CGFloat = 16
    static let reading = Font.system(size: readingSize)
    static let readingHeading = Font.system(size: readingHeadingSize, weight: .semibold)
    static let readingHeadingSize: CGFloat = 19
    nonisolated static let codeSize: CGFloat = 14
    static let code = Font.system(size: codeSize).monospaced()
    /// 注脚里的等宽字（一轮回答的工具清单）：比代码块小一档，是回答的注脚、不跟回答抢。
    static let codeNote = Font.system(size: 12).monospaced()
    static let inlineCode = code
    /// 阅读列的额外行距；总行高由系统字体与脚本度量决定。
    static let readingLineSpacing: CGFloat = 7
    /// 醒目的一句（等你确认的问题）。
    static let titleSize: CGFloat = 18
    static let title = Font.system(size: titleSize, weight: .semibold)
    /// 页内分组标题（最近、更早、现在、历史）与它旁边的计数。
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let sectionCount = Font.system(size: 13).monospacedDigit()
    /// 面板与文件页顶上的大标题（接入 Agent、技能的名字）。
    static let heading = Font.system(size: 22, weight: .semibold)
    /// ⌘K 搜索框的输入与右侧预览的标题：浮层里最大的两行字。
    static let searchField = Font.system(size: 18)
    static let previewTitle = Font.system(size: 17, weight: .bold)
    static let keycap = Font.system(size: 11, weight: .medium, design: .rounded)
    static let emptyTitle = Font.system(size: 17, weight: .semibold)
    /// 栏头（窗口最顶那一排）：钮上的字（收起、项目范围）；三栏栏头的标题只有一种（项目名、会话名与它前面的项目、Cue 的名字、页名），
    /// 下面或后面跟的那一行（项目介绍、Cue 的数字账）是 `toolbarSubtitle`；标题下面还有一行（任务 · 子任务）时标题收小，两行放进一个控件的高度。
    static let toolbarLabel = Font.system(size: 13, weight: .medium)
    static let toolbarTitle = Font.system(size: 15, weight: .semibold)
    static let toolbarTitlePaired = Font.system(size: 13, weight: .semibold)
    static let toolbarSubtitle = Font.system(size: 12)
    /// 看板列头：四列的列名与数同一个字号（同钮上的字），轻重只靠墨色分（`BoardWeight.swift`）。
    /// 否决过：等你的列头大一号、重的两列的数大一档——一排四个列头大小不一，读成没对齐。
    static let laneTitle = Font.system(size: 13, weight: .semibold)
    static let toolbarPath = Font.system(size: 11)
    static let cueCardName = Font.system(size: 18, weight: .semibold)
    /// 卡片摘要的额外行距；紧凑内容小于长文阅读。
    static let lineSpacing: CGFloat = 4
    static let gaugeNumber = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
    static let menuBarCount = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    /// 手机会话条格里最轻的那一行（哪家 Agent、哪个项目）：60 点宽的格放得下四五个字。Mac 上不出现，同 iOS 那一档。
    static let railTag = Font.system(size: 9, weight: .medium)
    #else
    static let body = Font.body
    static let bodyStrong = Font.headline
    static let secondary = Font.subheadline
    static let meta = Font.footnote
    static let label = Font.caption.weight(.semibold)
    static let sectionTitle = Font.headline
    static let caption = Font.caption
    static let caption2 = Font.caption2
    static let reading = Font.body
    static let readingHeading = Font.title3.weight(.semibold)
    static let code = Font.footnote.monospaced()
    static let codeNote = Font.caption.monospaced()
    static let inlineCode = Font.callout.monospaced()
    static let readingLineSpacing: CGFloat = 4
    static let sectionCount = Font.footnote.monospacedDigit()
    /// 宽屏栏头的标题与它后面那一行（iPad，同 Mac 那两档的角色）；页顶玻璃里两行的标题是 `toolbarTitlePaired`，下面那一行仍是 `toolbarSubtitle`。
    static let toolbarTitle = Font.headline
    static let toolbarTitlePaired = Font.subheadline.weight(.semibold)
    static let toolbarSubtitle = Font.caption
    /// 钮上的字（分段的各段）。手机上半粗：触屏的段比 Mac 宽，中号字重在玻璃上发虚。
    static let toolbarLabel = Font.subheadline.weight(.semibold)
    /// 看板列头（横屏与 iPad 四列）：列名与数，同 Mac 那一档的角色。
    static let laneTitle = Font.headline
    static let title = Font.title3.weight(.semibold)
    /// 文件页顶上的大标题（技能的名字），同 Mac 那一档的角色。
    static let heading = Font.title2.weight(.bold)
    static let emptyTitle = Font.title3.weight(.semibold)
    static let gaugeNumber = Font.system(.body, design: .rounded, weight: .semibold).monospacedDigit()
    /// 底栏上的字：栏高固定，不随动态字体。
    static let dockLabel = Font.system(size: 12, weight: .medium)
    /// 手机会话条格里最轻的那一行（哪家 Agent、哪个项目）：60 点宽的格放得下四五个字；格高随字号（`SessionRail`），这一行不随。
    static let railTag = Font.system(size: 9, weight: .medium)
    /// 预览页里整份文件的等宽字（UIKit 文本视图）。
    static let codeUIFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    #endif

    /// 全屏预览里的改动（`PreviewDiff`）与它的缩略图：定宽的等宽字，行底按字数×字宽铺满（横着滚到哪都连得上），所以两端同一号、不随动态字体。
    nonisolated static let diffSize: CGFloat = 12
    static let diff = Font.system(size: diffSize, design: .monospaced)
    static let diffStrong = Font.system(size: diffSize, weight: .semibold, design: .monospaced)
    /// SF Mono 的字宽是字号的 0.6。
    nonisolated static let diffCell: CGFloat = diffSize * 0.6

    /// 全屏预览里 Markdown 的文稿排版（`MarkdownText.Style.document`）：标题三级，比对话里的回答拉开层级。
    #if os(macOS)
    static let documentTitle = Font.system(size: 26, weight: .bold)
    static let documentHeading = Font.system(size: 21, weight: .semibold)
    #else
    static let documentTitle = Font.title.weight(.bold)
    static let documentHeading = Font.title2.weight(.semibold)
    #endif

    /// 紧凑的多行旁注（规则摘要、运行日志），不沿用长文阅读的疏行距。
    static let noteLineSpacing: CGFloat = 2
    static let taskLineSpacing: CGFloat = 5
    static let editorHeadingSpacing: CGFloat = 10

    /// 一个换行撑出的空行：`Text` 不认段距，块与块之间用一个这个字号的换行拉开。
    static func gap(_ height: CGFloat) -> Font { .system(size: height) }
}
