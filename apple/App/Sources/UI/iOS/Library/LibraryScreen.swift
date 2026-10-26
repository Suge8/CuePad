#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的技能与说明（Cue 名牌的面板那一行推入，`Route.library`）：看的是 Cue 运行那台 Mac 报上来的快照（`Workspace.library`），
/// 页顶写是哪台、多久前报的；一列排下要整理、说明、技能（同 Mac 的三组，`LibrarySections`）。手机上的整理与改说明都发往那台 Mac 去做。
/// 一台 Mac 都还没报过时只写一句先去 Mac 上打开 CuePad。
struct LibraryScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var mac: MacAgents?

    var body: some View {
        ScrollView {
            if let library = workspace.library {
                let columns = library.agents
                VStack(alignment: .leading, spacing: 28) {
                    if !library.tidies.isEmpty { TidySection(library: library).transition(.opacity) }
                    InstructionSection(library: library, columns: columns)
                    SkillSection(library: library, columns: columns)
                }
                .animation(HandOff.quick, value: library.tidies.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            } else {
                Text("在 Mac 上打开 CuePad，它会把那台的技能与说明报过来")
                    .font(.subheadline).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.top, 80)
            }
        }
        .floatingHeader("技能与说明", detail: source)
        .observing(services.store, id: workspace.library?.hostID, into: $mac, onError: workspace.fail) { [host = workspace.library?.hostID ?? ""] in
            try $0.macAgents(on: host)
        }
    }

    /// 页顶第二行：哪台 Mac、多久前报的（`AgentLibrary.modifiedAt`）。还没读到那台的名字时先空着占位。
    private var source: Dotted {
        guard let library = workspace.library else { return Dotted("") }
        return Dotted(mac?.shownName ?? "", DateLabel.short(library.modifiedAt))
    }
}
#endif
