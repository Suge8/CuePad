#if os(macOS)
import CuePi
import CueStore
import SwiftUI

nonisolated private struct SidebarData: Sendable {
    var trashCount: Int
    /// 同步记录里在线的会话（含别的 Mac 上的）与最近结束的几个（项目已删的不再带项目），以及全部会话数。
    var live: [PiSessionState]
    var ended: [PiSessionState]
    var sessionTotal: Int
    /// 发给这些会话的最近一条投送请求（Pi 的会话 id →）。
    var deliveries: [String: DeliveryRequest]
}

struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: SidebarData?
    @State private var creating = false
    @State private var renaming: Project?
    /// 点过侧栏里的页后焦点留在侧栏，方向键才有地方去
    @FocusState private var focused: Bool

    nonisolated private static let endedPage = PiSection.pastLimit * 2
    private static let footerFade: CGFloat = 16

    var body: some View {
        // 不用 List 的选中：系统选中是灰胶囊，压不过墨色体系；当前页由 PageRow 自己画，方向键由 onMoveCommand 接管
        let catalog = workspace.catalog
        let pages = data.flatMap { data in catalog.map { SidebarPages($0, trashCount: data.trashCount) } }
        List {
            if let data, let catalog, let pages {
                if !pages.pinned.isEmpty {
                    Section("置顶") { ForEach(pages.pinned) { row($0, catalog) } }
                }
                // 只有内容才有意义的分组，空的时候不出现
                if !pages.recent.isEmpty || pages.inboxCount > 0 {
                    Section("最近") {
                        ForEach(pages.recent) { row($0, catalog) }
                        if pages.inboxCount > 0 {
                            PageRow(page: .inbox, count: pages.inboxCount, select: select) {
                                Label("未分类", systemImage: "tray")
                            }
                        }
                    }
                }
                PiSection(recorded: data.live + data.ended, deliveries: data.deliveries, total: data.sessionTotal)
                if pages.showsTrash {
                    Section {
                        PageRow(page: .archive, count: 0, select: select) {
                            Label("归档", systemImage: "archivebox")
                        }
                        PageRow(page: .trash, count: data.trashCount, select: select) {
                            Label("回收站", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(SessionDetailHost(arrowEdge: .trailing))
        .focusable()
        .focused($focused)
        // 选中样式本身就标出了位置，不再套系统焦点环
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let order = pages?.order, let page = Self.page(after: workspace.page, in: order, moving: direction) else { return }
            workspace.show(page)
        }
        // 侧栏比桌面深一档：浅色、深色都能看出分层，与内容同一色温
        .scrollContentBackground(.hidden)
        .background(palette.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(isPresented: $creating) { ProjectForm(project: nil) }
        .sheet(item: $renaming) { ProjectForm(project: $0) }
        .observing(services.store, [.projects, .cards, .piSessionStates, .deliveryRequests], into: $data, onError: workspace.fail) { store in
            let live = try store.piSessionPage(.live)
            // 多取几条：本机刚结束、桥上已经重新连上的会话会被在线的那一行顶掉
            let ended = try store.piSessionPage(PiSessionQuery(scope: .ended, limit: Self.endedPage))
            return SidebarData(
                trashCount: try store.trashedProjects().count + store.trashedCards().count,
                live: live.items.map(\.listed), ended: ended.items.map(\.listed), sessionTotal: live.total + ended.total,
                deliveries: Dictionary((live.items + ended.items).compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first })
        }
    }

    private func select(_ page: Workspace.Page) {
        workspace.show(page)
        focused = true
    }

    /// 方向键：上一页 / 下一页，到头不循环；当前页不在侧栏里时从第一页开始。
    private static func page(after current: Workspace.Page, in order: [Workspace.Page], moving direction: MoveCommandDirection) -> Workspace.Page? {
        guard let index = order.firstIndex(of: current) else { return order.first }
        switch direction {
        case .up: return index > order.startIndex ? order[index - 1] : nil
        case .down: return index + 1 < order.endIndex ? order[index + 1] : nil
        default: return nil
        }
    }

    private func row(_ project: Project, _ catalog: ProjectCatalog) -> some View {
        PageRow(page: .project(project.id), count: catalog.cardCounts[project.id] ?? 0, select: select) {
            Label {
                Text(project.name)
            } icon: {
                ProjectGlyph(project: project)
            }
        }
        .contextMenu { ProjectMenu(project: project, rename: { renaming = project }) }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            ExtensionConsent()
            StartupIssues()
            HStack {
                // 整排设了次要前景色，系统的禁用变灰显不出来：不可用时自己降一档
                Button("新建项目", systemImage: "plus") { creating = true }
                    .disabled(!workspace.isLibraryReady)
                    .foregroundStyle(workspace.isLibraryReady ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                Spacer()
                Button("设置", systemImage: "gearshape") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
                    .help("设置（⌘,）")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 6)
        // 底栏是实底：列表滚到这里先淡掉，不压在"+"与齿轮上
        .background(palette.sidebar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            LinearGradient(colors: [palette.sidebar.opacity(0), palette.sidebar], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.footerFade)
                .offset(y: -Self.footerFade)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// 侧栏里能去的页，按显示顺序：置顶项目 → 最近项目 → 未分类 → 回收站。分组显示与方向键共用这一份顺序。
private struct SidebarPages {
    let pinned: [Project]
    let recent: [Project]
    let inboxCount: Int
    let showsTrash: Bool

    init(_ catalog: ProjectCatalog, trashCount: Int) {
        pinned = catalog.projects.filter(\.isPinned)
        recent = catalog.projects.filter { !$0.isPinned }
        inboxCount = catalog.cardCounts[nil] ?? 0
        showsTrash = trashCount > 0 || !catalog.projects.isEmpty
    }

    var order: [Workspace.Page] {
        (pinned + recent).map { .project($0.id) } + (inboxCount > 0 ? [.inbox] : []) + (showsTrash ? [.archive, .trash] : [])
    }
}

/// 侧栏里通向一页的一行：当前页垫选中底色、文字加粗；其余用 85% 的墨，不发灰。
private struct PageRow<Title: View>: View {
    let page: Workspace.Page
    let count: Int
    let select: (Workspace.Page) -> Void
    @ViewBuilder let title: Title
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static var restingOpacity: Double { 0.85 }

    var body: some View {
        let selected = workspace.page == page
        Button { select(page) } label: {
            HStack(spacing: 6) {
                title.fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(palette.ink3)
                }
            }
            .foregroundStyle(selected ? palette.ink : palette.ink.opacity(Self.restingOpacity))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // macOS 不把按钮的"已选中"特征交给读屏，当前页另用值念出来
        .accessibilityValue(selected ? "当前页" : "")
    }
}

/// 全局 Pi：与 iOS 的 Agent 页同一种行（`PiSessionRow`）、同一个顺序（`sidebarRows`）。点开任一会话是它的详情（近况与回复），
/// 在线会话右键可跳到所在终端、悬停看出错原文；标题旁的 + 开新会话；会话比显示的多时底部"全部 N 个"打开 ⌘K 的会话范围。
/// 没有活着的会话时分组不消失：一行"在终端运行 pi 开始"，下面照常是已结束的。没装 Pi 或版本太低时，这里是一行引导，点开说明怎么装。
private struct PiSection: View {
    let recorded: [PiSessionState]
    let deliveries: [String: DeliveryRequest]
    let total: Int
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.openSessionSearch) private var openSessionSearch
    @State private var startingSession = false

    nonisolated static let pastLimit = 5

    var body: some View {
        let status = services.piExtension.status
        let live = services.pi.sessions
        let rows = PiSessionState.sidebarRows(
            live: live.map {
                PiSessionState.live(
                    $0, hostID: services.hostID, projectID: workspace.sessionProjects[$0.id], recap: workspace.sessionRecaps[$0.sessionID])
            },
            recorded: recorded, deliveries: deliveries, pastLimit: Self.pastLimit)
        if let installation = status?.pi, !installation.isSupported {
            Section("Pi") { PiSetupRow(installation: installation) }
        } else if status != nil || !rows.isEmpty {
            Section {
                if live.isEmpty {
                    // 拒绝过安装扩展时，会话不会出现在这里：说清去哪装，而不是让人对着"运行 pi"困惑
                    let declined = status?.file != .current && services.settings.piExtensionDeclined
                    Label(declined ? "在 设置 › Pi 里安装扩展后显示会话" : "在终端运行 pi 开始", systemImage: "terminal")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .selectionDisabled()
                }
                // 在线与已结束同一个列表、按会话 id 区分：会话结束时详情不被关掉（详情挂在列表上，见 SessionDetailHost）
                ForEach(rows, id: \.sessionID) { session in
                    let bridge = live.first { $0.sessionID == session.sessionID }
                    PiSessionRow(session: session, project: workspace.catalog?.project(session.projectID), delivery: deliveries[session.sessionID])
                        .sessionDetailRow(session.sessionID)
                        .help(bridge?.state.errorMessage ?? "")
                        .contextMenu {
                            if let bridge, !bridge.hosted {
                                Button("跳到所在终端", systemImage: "terminal") { workspace.jumpToTerminal(bridge.id) }
                            }
                        }
                }
                if total > rows.count {
                    Button { openSessionSearch?() } label: {
                        Label("全部 \(total) 个", systemImage: "rectangle.stack").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .help("在 ⌘K 里按项目查看、搜索全部会话")
                }
            } header: {
                HStack {
                    Text("Agent")
                    Spacer()
                    NewSessionButton(recent: recorded, showing: $startingSession)
                }
                // 系统把分组标题连同 + 合成一个读屏元素，默认动作是收起分组：+ 另给一个具名动作
                .accessibilityAction(named: "新会话") { startingSession = true }
            }
        }
    }
}

extension PiSessionState {
    /// 侧栏 Pi 分组的行：本机在线的（桥上实时，`live`）与同步记录里没结束的（别的 Mac 上的）一起按要你注意的先后，
    /// 其后是已结束的；同一个会话只出现一次（本机实时优先），已结束的最多 `pastLimit` 行。`recorded` 是会话列表查询的一页。
    static func sidebarRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], pastLimit: Int
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) }
        let past = others.filter { $0.state == .known(.ended) }.prefix(pastLimit)
        return inListOrder(live + others.filter { $0.state != .known(.ended) }, deliveries: deliveries) + past
    }
}

/// 没装 Pi 或版本太低：侧栏 Pi 分组里的一行引导，点开是安装说明（`PiSetupGuide`）。
private struct PiSetupRow: View {
    let installation: PiInstallation
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(installation == .notFound ? "安装 Pi" : "升级 Pi").foregroundStyle(.primary)
                    Text("把灵感和任务直接发进 Pi").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "terminal")
            }
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            PiSetupGuide(installation: installation).padding(16).frame(width: 360)
        }
    }
}

/// 首次检测到 Pi 而扩展未装（或已过期）时征求同意；拒绝后同一版本不再询问。
private struct ExtensionConsent: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var installing = false

    var body: some View {
        if services.piExtension.needsConsent {
            VStack(alignment: .leading, spacing: 8) {
                Label("连接 Pi", systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                Text("安装 CuePad 扩展后，这里能看到 Pi 会话的实时状态，并能把灵感和任务直接发进会话。会写入 Pi 的扩展目录。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("不用了") {
                        withAnimation(.easeOut(duration: 0.15)) { services.piExtension.decline() }
                        workspace.say("之后可在 设置 › Pi 里安装")
                    }
                    Button("安装") { install() }.buttonStyle(.borderedProminent).disabled(installing)
                }
                .controlSize(.small)
            }
            .padding(12)
            .paper(radius: 12)
            .padding(.horizontal, 10)
            .transition(.opacity)
        }
    }

    private func install() {
        installing = true
        Task {
            defer { installing = false }
            do {
                try await services.piExtension.install()
                workspace.say("扩展已安装；已在运行的 Pi 会话重启后生效")
            } catch {
                workspace.fail(error)
            }
        }
    }
}

/// 启动时没能完成的事：只在有问题时出现，点开看详情。
private struct StartupIssues: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showing = false

    var body: some View {
        if !services.startupIssues.isEmpty {
            Button {
                showing.toggle()
            } label: {
                Label("\(services.startupIssues.count) 个启动问题", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(palette.attention)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(services.startupIssues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.text).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
                .padding(14).frame(width: 340, alignment: .leading)
            }
        }
    }
}
#endif
