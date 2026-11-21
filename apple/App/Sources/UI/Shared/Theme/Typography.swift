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
    nonisolated static let bodySize: CGFloat = 14
    static let body = ui(bodySize)
    static let bodyStrong = ui(15, .semibold)
    static let secondary = ui(13)
    static let meta = ui(12)
    static let label = ui(12, .semibold)
    static let caption = ui(12)
    static let caption2 = ui(11)
    nonisolated static let readingSize: CGFloat = 16
    static let reading = Font.system(size: readingSize)
    static let readingHeading = Font.system(size: readingHeadingSize, weight: .semibold)
    static let readingHeadingSize: CGFloat = 19
    nonisolated static let codeSize: CGFloat = 14
    static let code = Font.system(size: codeSize).monospaced()
    static let codeNote = Font.system(size: 12).monospaced()
    static let inlineCode = code
    static let readingLineSpacing: CGFloat = 7
    static let titleSize: CGFloat = 18
    static let title = ui(titleSize, .semibold)
    static let sectionTitle = ui(15, .semibold)
    static let sectionCount = ui(13)
    static let heading = ui(22, .semibold)
    static let searchField = Font.system(size: 18)
    static let previewTitle = ui(17, .bold)
    static let keycap = Font.system(size: 11, weight: .medium, design: .rounded)
    static let emptyTitle = ui(17, .semibold)
    static let toolbarLabel = ui(13, .medium)
    static let toolbarTitle = ui(15, .semibold)
    static let toolbarTitlePaired = ui(14, .semibold)
    static let toolbarSubtitle = ui(11)
    static let laneTitle = ui(13, .semibold)
    static let cueCardName = ui(18, .semibold)
    static let lineSpacing: CGFloat = 4
    static let gaugeNumber = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
    static let menuBarCount = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    #else
    static let body = ui(.body)
    static let bodyStrong = ui(.headline, .semibold)
    static let secondary = ui(.subheadline)
    static let meta = ui(.footnote)
    static let label = ui(.caption, .semibold)
    static let sectionTitle = ui(.headline, .semibold)
    static let caption = ui(.caption)
    static let caption2 = ui(.caption2)
    static let reading = Font.body
    static let readingHeading = Font.title3.weight(.semibold)
    static let code = Font.footnote.monospaced()
    static let codeNote = Font.caption.monospaced()
    static let inlineCode = Font.callout.monospaced()
    static let readingLineSpacing: CGFloat = 4
    static let sectionCount = ui(.footnote)
    static let toolbarTitle = ui(.headline, .semibold)
    static let toolbarTitlePaired = ui(.callout, .semibold)
    static let toolbarSubtitle = ui(.caption2)
    static let toolbarLabel = ui(.subheadline, .semibold)
    static let laneTitle = ui(.headline, .semibold)
    static let title = ui(.title3, .semibold)
    static let heading = ui(.title2, .bold)
    static let emptyTitle = ui(.title3, .semibold)
    static let cueCardName = ui(.title3, .bold)
    static let cueCardNameCompact = ui(.subheadline, .semibold)
    static let gaugeNumber = Font.system(.body, design: .rounded, weight: .semibold).monospacedDigit()
    static let codeUIFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    #endif

    nonisolated static let diffSize: CGFloat = 12
    static let diff = Font.system(size: diffSize, design: .monospaced)
    static let diffStrong = Font.system(size: diffSize, weight: .semibold, design: .monospaced)
    /// SF Mono 的字宽是字号的 0.6。
    nonisolated static let diffCell: CGFloat = diffSize * 0.6

    #if os(macOS)
    static let documentTitle = Font.system(size: 26, weight: .bold)
    static let documentHeading = Font.system(size: 21, weight: .semibold)
    #else
    static let documentTitle = Font.title.weight(.bold)
    static let documentHeading = Font.title2.weight(.semibold)
    #endif

    static let taskLineSpacing: CGFloat = 5
    static let editorHeadingSpacing: CGFloat = 10

    /// 一个换行撑出的空行：`Text` 不认段距，块与块之间用一个这个字号的换行拉开。
    static func gap(_ height: CGFloat) -> Font { .system(size: height) }
}
