#if os(macOS)
import SwiftUI

/// 侧栏项目区下面、底栏上面的一行额度（`QuotaRings` 的 `row`：左边"额度"、环靠右，同"项目"区头的两端）：点它从这一行上方长出明细的气泡（`QuotaDetail`）。
/// Mac 主窗口里额度只在这一处：额度是整个 App 的（`AppServices.accountQuotas`），不属于哪一页，侧栏在每页都看得见。
/// 侧栏收起时窗口里没有额度，看菜单栏面板里那一份（`MenuBarPad`）；工具栏不另留一份。
/// 行高固定（`Spacing.sidebarRow`），环最多三颗、靠右长：有没有额度、几家都不挪别的行，侧栏最窄（`MainWindow` 的最小宽）时也放得下。
/// 环出现与明细打开时，数据陈旧就查一次（`refreshesQuota`）。
/// 否决过：放进底栏设置钮左边（四颗圆钮加两三颗环超出侧栏最小宽）、放进 Cue 名片（名片说的是 Cue，环比名字那一行高，名片跟着变高）。
struct SidebarQuota: View {
    @State private var open = DebugHooks.preset.quotaOpen
    /// 收起的时刻：按在环上收起的，松开时不再打开（`PressPoint.reopens`）。
    @State private var closed: ContinuousClock.Instant?

    var body: some View {
        QuotaRings(open: open, height: Spacing.sidebarRow, row: true) { open = !open && !PressPoint.reopens(closedAt: closed) }
            .bubble(isPresented: $open) { QuotaDetail().padding(16).refreshesQuota() }
            .onChange(of: open) { _, open in if !open { closed = .now } }
            .refreshesQuota()
    }
}
#endif
