#if os(macOS)
import CueStore
import SwiftUI

/// 菜单栏面板：最上面一行 Cue（点它在主窗口里打开 Cue 页）与额度环（`QuotaRings`，点它就地展开明细 `QuotaDetail`，再点收回；面板弹出时数据陈旧就查一次，见 `AppDelegate`），
/// 那一行的第二行是数字账（`CueLedger`，同名牌）；
/// 其下在做的会话（`MenuBarLive`，没有在做的不出这一块），最后是随手记（与主窗口底部同一个 `CaptureComposer`，一直展开；"交给 Cue"在它头部右边）。
/// Cue 那一行右边只放额度环：数字账要写全拍板、待回复、推进中、子代理四样，再放一颗"交给 Cue"就只剩六十来点宽。
/// 面板最高到屏幕可用的高（`MenuBarPanel`），放不下时"在做"那一块在里面滚，其余几块始终整块可见。
/// 各块各是一片玻璃、中间留空，面板自己没有底（输入框自带玻璃，外面再包一层就是玻璃套玻璃）。资料库读到之前没有输入框；读不出来时说明原因并给"重试"。
struct MenuBarPad: View {
    var open: (Route) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var capture = CaptureState()
    @State private var quotaOpen = false

    private static let blockRadius: CGFloat = 22
    private static let blockPadding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.isLibraryReady { cueRow }
            if quotaOpen, !services.accountQuotas.items.isEmpty { QuotaDetail().modifier(Block()) }
            let rows = workspace.liveWork
            if !rows.isEmpty {
                MenuBarLive(rows: rows, open: open)
                    .modifier(Block())
                    // 屏幕矮、面板放不下时只有这一块让出高度（在里面滚）：Cue 行、额度与随手记始终整块可见
                    .layoutPriority(-1)
            }
            if workspace.isLibraryReady {
                CaptureComposer(state: $capture, defaultProject: services.settings.currentProject, pinnedOpen: true)
            } else if let failure = workspace.catalogFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text("读不出资料库") } icon: { FailureMark() }.font(Typography.secondary.weight(.medium))
                    Text(failure).font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(4)
                    Button("重试") { workspace.retryCatalog() }
                }
                .foregroundStyle(palette.ink)
                .modifier(Block())
            }
        }
        .frame(width: 360)
    }

    private var cueRow: some View {
        CueStatusRow {
            QuotaRings(open: quotaOpen, height: 28) { quotaOpen.toggle() }
        }
        .contentShape(.rect)
        .onTapGesture { open(.cue) }
        .accessibilityAction(named: "打开 \(workspace.cue.name)") { open(.cue) }
        .modifier(Block())
    }

    private struct Block: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(MenuBarPad.blockPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(in: .rect(cornerRadius: MenuBarPad.blockRadius))
        }
    }
}
#endif
