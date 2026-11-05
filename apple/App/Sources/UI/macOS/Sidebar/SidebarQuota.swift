#if os(macOS)
import SwiftUI

/// 宽屏会话条最底下那一行的左边（`WideRail`，`QuotaRings` 的 `cell`：只有环，右边是技能与规则、设置两颗钮）：点它从这一行上方长出明细的气泡（`QuotaDetail`）。
/// 不再写"额度"二字：环本身就是读数，那一行别的都只画图标；还没有环时环的位置写"额度"（`QuotaRings`）。
/// Mac 主窗口里额度只在这一处：额度是整个 App 的（`AppServices.accountQuotas`），不属于哪一页，会话条在每页都看得见。
/// 会话条藏起时窗口里没有额度，看菜单栏面板里那一份（`MenuBarPad`）；栏头不另留一份。
/// 高同那一行的钮（`Chrome.control`），环最多三颗、往右长：有没有额度、几家都不挪别的钮，256 宽的会话条里连同两颗钮也放得下。
/// 环出现与明细打开时读取账号清单（`refreshesQuota`），不定时查询。
/// 否决过：放进底栏设置钮左边（四颗圆钮加两三颗环超出侧栏最小宽）、放进 Cue 名片（名片说的是 Cue，环比名字那一行高，名片跟着变高）。
struct SidebarQuota: View {
    @Environment(AppServices.self) private var services
    /// 按在环上收起的，松开时不再打开（`BubbleSwitch`）。
    @State private var detail = BubbleSwitch(open: DebugHooks.preset.quotaOpen)

    var body: some View {
        QuotaRings(open: detail.open, height: Chrome.control, cell: true) { detail.toggle() }
            .bubble(isPresented: $detail.open, width: QuotaDetail.bubbleWidth(accounts: services.accountQuotas.items.count)) { QuotaDetail().padding(Self.padding).refreshesQuota() }
            .refreshesQuota()
    }

    static let padding: CGFloat = 16
}
#endif
