#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的技能与规则（Cue 名牌的面板那一行推入，`Route.library`；底部那一排让开，`Dock.stays`）：看的是 Cue 运行那台 Mac 报上来的快照（`Workspace.library`）。
/// Mac 上并排的两列在这里是两段，页顶中间那块玻璃里换（规则｜技能，`LibraryTabs`），它也是页名，不另写标题，段里也不再写组名；
/// 右边一颗问号，点开是说明的气泡（`LibraryHelp`，贴在底部的纸：哪台 Mac、多久前报的也在里面）。一键整理那块纸各段只列这一段的事，排在最上面（`TidySlot`）。
/// 一台 Mac 都还没报过时只写一句先去 Mac 上打开 CuePad。
struct LibraryScreen: View {
    enum Tab: CaseIterable { case rules, skills }

    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var tab = DebugHooks.preset.libraryTab
    @State private var helpOpen = false

    var body: some View {
        ScrollView {
            if let library = workspace.library {
                Group {
                    switch tab {
                    case .rules: InstructionSection(library: library)
                    case .skills: SkillSection(library: library)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            } else {
                Text("在 Mac 上打开 CuePad，它会把那台的技能与规则报过来")
                    .font(.subheadline).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.top, 80)
            }
        }
        // 同手机的任务气泡，贴在底部的纸：问号在系统导航栏里，栏里的项量不出能对上页面的框，气泡也盖不过导航栏
        .panel(isPresented: $helpOpen, style: .bubble(.bottom)) {
            if let library = workspace.library { LibraryHelp(library: library) }
        }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("技能与规则", center: { LibraryTabs(tab: $tab) }) {
            Button("说明", icon: .help) { helpOpen.toggle() }
                .disabled(workspace.library == nil)
        }
    }
}

/// 页顶中间那块玻璃：规则｜技能两段，两颗等宽、英文下也不换形。
private struct LibraryTabs: View {
    @Binding var tab: LibraryScreen.Tab
    private static let inset: CGFloat = 3
    private static let width: CGFloat = 76

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryScreen.Tab.allCases, id: \.self) { item in
                PaneButton(title: title(item), on: tab == item) { tab = item } label: {
                    Text(title(item)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .frame(minWidth: Self.width).padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(Self.inset)
        .headerPiece()
    }

    private func title(_ tab: LibraryScreen.Tab) -> LocalizedStringResource {
        switch tab {
        case .rules: "规则"
        case .skills: "技能"
        }
    }
}
#endif
