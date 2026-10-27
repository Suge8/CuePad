#if os(macOS)
import SwiftUI

/// 侧栏底栏的额度环（`QuotaRings`，设置钮左边）：点它从环上长出明细的气泡（`QuotaDetail`，底栏下面放不下，摆在上面）。
/// Mac 主窗口里额度只在这一处：额度是整个 App 的（`AppServices.accountQuotas`），不属于哪一页，侧栏在每页都看得见。
/// 侧栏收起时窗口里没有额度，看菜单栏面板里那一份（`MenuBarPad`）；工具栏不另留一份。
/// 环数随账号增减，宽度只往左长、贴着设置钮，高同底栏圆钮：归档、回收站、设置与整列侧栏都不动。
/// 环出现与明细打开时，数据陈旧就查一次（`refreshesQuota`）。
/// 否决过：放进 Cue 名片（名片说的是 Cue，环比名字那一行高，名片跟着变高）、项目列表下另起一行"额度"（多一个区头，又占一行高）。
struct SidebarQuota: View {
    @State private var open = DebugHooks.preset.quotaOpen
    /// 收起的时刻：按在环上收起的，松开时不再打开（`PressPoint.reopens`）。
    @State private var closed: ContinuousClock.Instant?

    var body: some View {
        QuotaRings(open: open, height: SidebarMetrics.footerButton) { open = !open && !PressPoint.reopens(closedAt: closed) }
            .bubble(isPresented: $open) { QuotaDetail().padding(16).refreshesQuota() }
            .onChange(of: open) { _, open in if !open { closed = .now } }
            .refreshesQuota()
    }
}
#endif
