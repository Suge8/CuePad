#if os(macOS)
import SwiftUI

/// 宽屏会话条最底下那一行的左边（`WideRail`，`QuotaRings` 的 `row`：左边"额度"、环靠右，右边是技能与规则、设置两颗钮）：点它从这一行上方长出明细的气泡（`QuotaDetail`）。
/// Mac 主窗口里额度只在这一处：额度是整个 App 的（`AppServices.accountQuotas`），不属于哪一页，会话条在每页都看得见。
/// 会话条收成 80 的图标条时窗口里没有额度，看菜单栏面板里那一份（`MenuBarPad`）；栏头不另留一份。
/// 行高固定（`Spacing.sidebarRow`），环最多三颗、靠右长：有没有额度、几家都不挪别的行，256 宽的会话条里连同两颗钮也放得下。
/// 环出现与明细打开时读取账号清单（`refreshesQuota`），不定时查询。
/// 否决过：放进底栏设置钮左边（四颗圆钮加两三颗环超出侧栏最小宽）、放进 Cue 名片（名片说的是 Cue，环比名字那一行高，名片跟着变高）。
struct SidebarQuota: View {
    @Environment(AppServices.self) private var services
    @State private var open = DebugHooks.preset.quotaOpen
    /// 收起的时刻：按在环上收起的，松开时不再打开（`PressPoint.reopens`）。
    @State private var closed: ContinuousClock.Instant?

    var body: some View {
        QuotaRings(open: open, height: Spacing.sidebarRow, row: true) { open = !open && !PressPoint.reopens(closedAt: closed) }
            .font(Typography.sidebarHeader)
            .bubble(isPresented: $open, width: QuotaDetail.bubbleWidth(accounts: services.accountQuotas.items.count)) { QuotaDetail().padding(Self.padding).refreshesQuota() }
            .onChange(of: open) { _, open in if !open { closed = .now } }
            .refreshesQuota()
    }

    static let padding: CGFloat = 16
}
#endif
