#if os(iOS)
import CueStore
import SwiftUI

struct IOSRoot: View {
    let services: AppServices
    /// 本窗口的工作区：出现时建（`onAppear` 在第一帧之前做完，第一帧照样是建好的样子），不在 init 里建：init 在上一层的 body 里跑，
    /// 建它时读到的（Cue 的现状、说话的时钟）会被记成上一层的依赖，它们一变上一层就重算、再白建一个工作区（当场读一遍资料库），
    /// 连带整个窗口的根与导航栈重建——Cue 一动一帧里就重建好几遍。
    @State private var workspace: Workspace?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var zoom

    var body: some View {
        if let workspace {
            window(workspace)
        } else {
            Color.clear.onAppear { workspace = Workspace(services: services) }
        }
    }

    private func window(_ workspace: Workspace) -> some View {
        @Bindable var workspace = workspace
        return CatalogGate {
            Group {
                if sizeClass == .regular { SplitRoot() } else { NarrowRoot() }
            }
            // 正文、输入框里的附件在这里看（页里另挂了全屏页的用页里那个，带底栏）
            .previewPresenter($workspace.preview, reply: nil)
            .background { RootShortcuts() }
            .overlay {
                FloatingInput(isPresented: workspace.newSession != nil, close: { workspace.newSession = nil }) {
                    if let start = workspace.newSession { NewSessionInput(start: start).id(start.id) }
                }
            }
            .overlay {
                FloatingInput(isPresented: workspace.outbox != nil, close: { workspace.outbox = nil }) {
                    if let outbox = workspace.outbox { HandOffInput(outbox: outbox).id(outbox.id) }
                }
            }
            .sheet(item: $workspace.projectForm) { ProjectFormSheet($0) }
            .sheet(item: Binding(get: { workspace.folderPicker }, set: { workspace.folderPicker = $0 })) { FolderPickerSheet(project: $0) }
            .overlay { TaskBubbleSlot() }
            .overlay { CardMoreSlot() }
            .sessionAsks(workspace)
        }
        .watchesTouches { [workspace] in workspace.pressed(at: $0) }
        .measuresStatusBar()
        .overlay { StatusBarBlur() }
        .overlay(alignment: .top) { if sizeClass != .regular { NoticeBanner() } }
        .modifier(WindowCardAgents(workspace: workspace))
        .modifier(CueRelayStage(workspace: workspace))
        // 环境放在最外层：浮层与弹出面板是这些修饰符内容的兄弟，放在里面它们拿不到
        .environment(\.zoomNamespace, zoom)
        .environment(workspace)
        .environment(workspace.services)
        .onChange(of: sizeClass, initial: true) { workspace.setLayout(sizeClass == .regular ? .wide : .narrow) }
        .task { await workspace.follow() }
        .modifier(SessionViewing(keeper: workspace.services.viewer, workspace: workspace))
        .debugScene(workspace)
    }
}

/// 右边那一栏的页（侧栏选中的根页与其上推入的页都经这里）。页底色在这里一处铺在导航容器上：
/// 各页的内容要等读库（异步）才有，铺在滚动区上时数据没到的几帧整页透明、露出系统的黑。
struct RouteView: View {
    let route: Route
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.headerHost) private var host

    var body: some View {
        // 页顶由系统滚动边缘效果隔开正文；底部仍透过回复框，状态栏模糊由窗口负责。
        // 系统分组列表默认顶边清掉，第一行只按栏头安全区与 contentGap 让位。
        page.contentMargins(.top, 0, for: .scrollContent)
            .safeAreaPadding(.top, host == .navigationBar ? Bars.contentGap : 0)
            .containerBackground(background, for: .navigation)
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 导航栈里的页自己跟着键盘让位（UIKit 给的安全区，不经外层），菜单开着时在这里锁住
            .modifier(KeyboardHold())
    }

    private var background: Color {
        route.isCard && sizeClass != .regular ? palette.paper : palette.desk
    }

    @ViewBuilder private var page: some View {
        switch route {
        case .shelf: ShelfScreen()
        case .project(let id): ProjectScreen(projectID: id)
        case .archive: ArchiveList().floatingHeader("归档")
        case .trash: TrashScreen()
        case .settings: SettingsScreen()
        case .conflicts: ConflictsScreen()
        case .progress: ProgressScreen()
        case .cue: CuePage().countsAsViewer()
        case .search: SearchScreen()
        case .earlier: EarlierPage()
        case .library: LibraryScreen()
        case .libraryFile(let file): LibraryFileScreen(file: file)
        case .session(let route): SessionScreen(id: route.id, seed: route.seed).countsAsViewer()
        case .card(let id):
            if let zoom {
                CardEditorScreen(cardID: id).navigationTransition(.zoom(sourceID: id, in: zoom))
            } else {
                CardEditorScreen(cardID: id)
            }
        }
    }
}

struct RootShortcuts: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            Button("搜索") { workspace.openSearch() }.keyboardShortcut("k")
            Button("搜索") { workspace.openSearch() }.keyboardShortcut("f")
            // 搜索框没有焦点时 Esc 退出搜索（有焦点时第一下 Esc 由系统收起输入）
            if workspace.top == .search {
                Button("退出搜索") { workspace.closeSearch() }.keyboardShortcut(.escape, modifiers: [])
            }
            Button("记一条灵感") { workspace.newCard() }.keyboardShortcut("n")
            Button("对 Cue 说") { workspace.speakToCue() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("设置") { workspace.select(.settings) }.keyboardShortcut(",")
            Button("进展") { workspace.show(.progress) }.keyboardShortcut("t", modifiers: [.command, .shift])
            ForEach(Array(1...9).prefix(workspace.catalog?.projects.count ?? 0), id: \.self) { number in
                Button("项目 \(number)") { workspace.showProject(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .readerHidden(true)
    }
}
#endif
