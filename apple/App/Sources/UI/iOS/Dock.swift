#if os(iOS)
import SwiftUI

enum Dock {
    static let height: CGFloat = 62
    /// 离屏幕左、右、下边的空：同系统悬浮标签栏自带的边距（`DockTabs` 靠它对齐）。
    static let margin: CGFloat = 21
    /// 两块玻璃之间、Cue 页"⋯"与输入框之间的空。
    static let gap: CGFloat = 8
    /// 两格离底板两端的空（同系统标签栏的排法，`DockTabs`）。
    static let inset: CGFloat = 4
    /// Cue 页上收起时那颗"⋯"（与输入框同高）。
    static let slot = ComposerMetrics.slot
    /// 一格最宽：宽的窄窗口（iPad）里格子不再长，多出来的给 Cue 钮。
    static let maxCell: CGFloat = 76
    /// 两个去处，从左到右：项目、进展（进展挨着 Cue：会话在进展里，接力的光从 Cue 落到它那一格最近）。
    static let places: [SidebarOutline.Entry] = [.projects, .progress]
    /// 三个 tab 从左到右（两格去处，Cue 在最右）：左右滑切 tab 与点按换 tab 时整条滑的顺序（`DockPager`）。
    static let tabs: [Route] = places.map(\.route) + [.cue]

    /// 一格多宽：整排按格数分（每格去处一份、Cue 钮两份），中间不空；两格的胶囊与 Cue 钮差不多一样宽，不像缺了一格。
    static func cell(in width: CGFloat) -> CGFloat { min(maxCell, (width - gap - inset * 2) / CGFloat(places.count + 2)) }
    static func capsule(in width: CGFloat) -> CGFloat { cell(in: width) * CGFloat(places.count) + inset * 2 }

    static func order(_ tab: Route) -> Int { tabs.firstIndex(of: tab) ?? tabs.count - 1 }

    /// tab 根页页顶那一排的搜索入口：项目页中间没有别的，是铺满的一条搜索框；进展页中间放着这一页看什么，是左边一颗圆钮；
    /// Cue 页的焦点就是 Cue，没有。提示横幅按它决定盖多宽（`NoticeBanner`）。
    static func search(on route: Route) -> HeaderSearch? {
        switch route {
        case .shelf: .field
        case .progress: .button
        default: nil
        }
    }

    /// 这一页上留不留着底部那一排：往下钻的页都留着（项目、灵感、会话……，换 tab 随时点得到）；设置、技能与规则这类二级页让开，同系统设置里的子页。
    static func stays(on route: Route) -> Bool {
        switch route {
        case .settings, .conflicts, .library, .libraryFile: false
        default: true
        }
    }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }
}
#endif
