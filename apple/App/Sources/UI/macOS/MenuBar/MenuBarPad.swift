#if os(macOS)
import CueStore
import SwiftUI

/// Cue 那一行右边只放额度环：数字账要写全拍板、待回复、推进中、子代理四样，再放一颗"交给 Cue"就只剩六十来点宽。
/// 各块各是一片玻璃、中间留空，面板自己没有底（输入框自带玻璃，外面再包一层就是玻璃套玻璃）。
struct MenuBarPad: View {
    var open: (Route) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var capture = CaptureState()
    @State private var quotaOpen = false

    private static let blockPadding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if workspace.isLibraryReady { cueRow }
            if quotaOpen { QuotaDetail().modifier(Block()) }
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
                VStack(alignment: .leading, spacing: Spacing.item) {
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
            QuotaRings(open: quotaOpen, height: 28) { quotaOpen.toggle() }.refreshesQuota(open: quotaOpen)
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
                .glass(in: .rect(cornerRadius: Radius.sheet))
        }
    }
}
#endif
