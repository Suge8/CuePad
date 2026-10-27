#if os(iOS)
import CueStore
import SwiftUI

/// iOS/iPadOS 一个窗口的根视图（建出本窗口的 `Workspace`）：宽屏是分栏（`SplitRoot`），窄屏（iPhone 与窄窗口 iPad）
/// 是标签栏、每个 tab 一个导航栈（`DockRoot`）。两种容器读写同一份去处（`Workspace.root`、`stacks`），按尺寸类换 `Workspace.layout`。
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
                if sizeClass == .regular { SplitRoot() } else { DockRoot() }
            }
            .background { RootShortcuts() }
            // 会写资料库的面板挂在门内：读不出资料库时不弹出，读到后再弹；新会话与发给 Agent 都是浮在键盘上方的输入框
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
        }
        .watchesTouches { [workspace] in workspace.pressed(at: $0) }
        // 这一层还没有导航栏：上安全区就是状态栏
        .measuresStatusBar()
        .overlay { StatusBarBlur() }
        // 窄屏盖在整个窗口上；宽屏在右边那一栏里（`SplitRoot`）
        .overlay(alignment: .top) { if sizeClass != .regular { NoticeBanner() } }
        // 卡与行上"交给了哪个会话"的状态点读窗口里的那一份（`Workspace.agentLinks`）
        .modifier(WindowCardAgents(workspace: workspace))
        // Cue 与会话之间接力的那一下画在整个窗口上
        .modifier(CueRelayStage(workspace: workspace))
        // 环境放在最外层：浮层与弹出面板是这些修饰符内容的兄弟，放在里面它们拿不到
        .environment(\.zoomNamespace, zoom)
        .modifier(PaletteProvider())
        .environment(workspace)
        .environment(workspace.services)
        .onChange(of: sizeClass, initial: true) { workspace.layout = sizeClass == .regular ? .split : .dock }
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
        // 沉浸式：内容一直滚到顶栏、回复框的玻璃后面、透到屏幕最顶，玻璃本身就是遮挡，玻璃之间与下面的内容清楚可见——
        // 系统的滚动边缘效果（渐进模糊带，盖住整条栏）全关；状态栏那一条的模糊是整个窗口一份（`StatusBarBlur`）。
        // 内容离系统顶栏的距离只在这里给（`Bars.contentGap`，让出在上安全区里），静止时第一行在顶栏下面；页顶那一排自己画的页（窄屏的根）
        // 由那一排让（`FloatingHeader`）。系统分组列表默认在顶上再留一段空，这里清掉，离栏多远只有这一个数
        page.contentMargins(.top, 0, for: .scrollContent)
            .safeAreaPadding(.top, host == .navigationBar ? Bars.contentGap : 0)
            .containerBackground(background, for: .navigation)
            // 标题在页顶那一排中间的玻璃里或不写（根页），不用系统大标题
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectHidden()
            // 导航栈里的页自己跟着键盘让位（UIKit 给的安全区，不经外层），菜单开着时在这里锁住
            .modifier(KeyboardHold())
    }

    /// 卡片纸页在窄屏是整页的纸，宽屏是桌面上的一张纸；其余页是桌面。
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
        case .cue: CuePage().countsAsPiViewer()
        case .search: SearchScreen()
        case .library: LibraryScreen()
        case .libraryFile(let file): LibraryFileScreen(file: file)
        case .session(let route): SessionScreen(id: route.id, seed: route.seed).countsAsPiViewer()
        case .card(let id):
            if let zoom {
                CardEditorScreen(cardID: id).navigationTransition(.zoom(sourceID: id, in: zoom))
            } else {
                CardEditorScreen(cardID: id)
            }
        }
    }
}

/// 外接键盘快捷键（不占位的隐形按钮），两种容器同一组，与 Mac 对齐：⌘1–9 切项目、⌘K（及 ⌘F）搜索、⌘N 新建卡片、
/// ⌘⇧N 对 Cue 说、⌘⇧T 任务、⌘, 设置。⌘\ 开合侧栏只在宽屏，按侧栏此刻在不在旁边（`SplitRoot`）。
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
        .accessibilityHidden(true)
    }
}
#endif
