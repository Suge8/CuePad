#if os(macOS)
import CueStore
import SwiftUI

struct MenuBarPad: View {
    var open: (Route) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var capture = CaptureState()
    @State private var quotaOpen = false

    private static let blockPadding = Spacing.block

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if workspace.isLibraryReady { cueRow }
            if quotaOpen { QuotaDetail().modifier(Block()) }
            let rows = workspace.liveWork
            if !rows.isEmpty {
                MenuBarLive(rows: rows, open: open)
                    .modifier(Block())
                    .layoutPriority(-1)
            }
            if workspace.isLibraryReady {
                CaptureComposer(state: $capture, defaultProject: services.settings.currentProject)
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
