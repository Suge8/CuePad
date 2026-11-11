#if os(macOS)
import SwiftUI

/// Mac 主窗口里额度只在这一处：额度是整个 App 的（`AppServices.accountQuotas`），不属于哪一页；会话条藏起时窗口里没有额度，看菜单栏面板里那一份（`MenuBarPad`），栏头不另留一份。
/// 高同那一行的钮（`Chrome.control`），环最多三颗、往右长：有没有额度、几家都不挪别的钮，256 宽的会话条里连同两颗钮也放得下。
/// 不定时查询：环出现、可问的来源变了与明细打开时才读取账号清单（`refreshesQuota`）。
/// 否决过：放进底栏设置钮左边（四颗圆钮加两三颗环超出侧栏最小宽）、放进 Cue 名片（名片说的是 Cue，环比名字那一行高，名片跟着变高）。
struct SidebarQuota: View {
    @Environment(AppServices.self) private var services
    @State private var detail = BubbleSwitch(open: DebugHooks.preset.quotaOpen)

    var body: some View {
        QuotaRings(open: detail.open, height: Chrome.control, cell: true) { detail.toggle() }
            .bubble(isPresented: $detail.open, width: QuotaDetail.bubbleWidth(accounts: services.accountQuotas.items.count)) { QuotaDetail().padding(Self.padding) }
            .refreshesQuota(open: detail.open)
    }

    static let padding: CGFloat = 16
}
#endif
