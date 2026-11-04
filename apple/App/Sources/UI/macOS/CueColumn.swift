#if os(macOS)
import CueStore
import SwiftUI

/// 右边的 Cue（宽 400，`WideMetrics.cue`）：栏头在窗口最顶那一排（`CueTitle`），下面是 Cue 页（`CuePage`），对话裁在栏头下沿。
/// 收起与放不下时也一直挂着（`MainWindow` 只是藏起它）：`shown` 为假时这一页不在前台（暂停订阅与实时状态、不算在看 Cue，`pageActive`）。
struct CueColumn: View {
    let shown: Bool

    var body: some View {
        CatalogGate {
            VStack(spacing: 0) {
                CueTitle()
                CuePage().clipped()
            }
        }
        .environment(\.pageActive, shown)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Cue 的栏头（右边 Cue 那一栏顶上，手机与 iPad 是 `CueHeader`）：头像、名字、数字账一行（`CueLedger`，同手机名牌的第二行），右边记忆与定时两颗圆钮（`CueListSlots`）。
/// 点头像那一块把 Cue 收起成右上一颗钮（`CueButton`），收没收起是用户的选择（`AppSettings.cueOpen`）。输入框里有没说出去的话时头像露"在听"。
struct CueTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        HStack(spacing: 0) {
            Button {
                if workspace.cueFloats { workspace.cueFloats = false } else { services.settings.cueOpen = false }
            } label: {
                HStack(spacing: 8) {
                    CueAvatar(cue.beat, size: .row).relaySpot(cue: .header)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(cue.name).font(Typography.toolbarTitle).foregroundStyle(palette.ink).lineLimit(1)
                        CueStatusLine(tally: true, font: Typography.toolbarSubtitle).lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(.button))
            .help("收起 \(cue.name)")
            .accessibilityAddTraits(.isHeader)
            .animation(Motion.fade, value: cue.presence)
            Spacer(minLength: Spacing.toolbarGap)
            CueListSlots()
        }
        .padding(.horizontal, Spacing.page)
        .frame(height: Chrome.band)
        .windowDragArea()
    }
}

#endif
