import SwiftUI

nonisolated enum Spacing {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let glyph: CGFloat = 6
    /// 一行里相邻几样、一组里相邻两行与两块、卡与卡、一排里相邻两颗钮与胶囊；栏头里相邻两颗钮、两块玻璃（不共用系统玻璃底的项，系统不给留空）。
    static let item: CGFloat = 8
    static let group: CGFloat = 12
    static let block: CGFloat = 16
    static let part: CGFloat = 24
    static let sheet: CGFloat = 24
    #if os(macOS)
    static let inset: CGFloat = 12
    static let panel: CGFloat = 20
    static let page: CGFloat = 24
    static let section: CGFloat = 32
    static let vacant: CGFloat = 120
    static let pageTop: CGFloat = 24
    static let reading: CGFloat = 680
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
