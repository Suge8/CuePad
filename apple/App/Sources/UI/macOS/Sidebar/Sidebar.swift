#if os(macOS)
import CuePi
import CueStore
import SwiftUI

nonisolated private struct SidebarData: Sendable {
    var projects: [Project]
    var summaries: [UUID?: ProjectSummary]
    var trashCount: Int
    var history: [StoredPiSession]
    /// 历史会话（会话 id）归属的项目，由 Store 按工作目录判定。
    var historyProjects: [String: UUID]
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

    nonisolated private static let historyLimit = 5

    var body: some View {
        // 不用 List 的选中：系统选中是灰胶囊，压不过墨色体系；当前页由 PageRow 自己画，方向键由 onMoveCommand 接管
        let pages = data.map(SidebarPages.init)
        List {
            if let data, let pages {
                if !pages.pinned.isEmpty {
                    Section("置顶") { ForEach(pages.pinned) { row($0, data) } }
                }
                // 只有内容才有意义的分组，空的时候不出现
                if !pages.recent.isEmpty || pages.inboxCount > 0 {
                    Section("最近") {
                        ForEach(pages.recent) { row($0, data) }
                        if pages.inboxCount > 0 {
                            PageRow(page: .inbox, count: pages.inboxCount, select: select) {
                                Label("未归档", systemImage: "tray")
                            }
                        }
                    }
                }
                PiSection(history: data.history, historyProjects: data.historyProjects, projects: data.projects)
                if pages.showsTrash {
                    Section {
                        PageRow(page: .trash, count: data.trashCount, select: select) {
                            Label("回收站", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        .observing(services.store, [.projects, .cards, .piSessions], into: $data, onError: workspace.fail) { store in
            let summaries = try store.projectSummaries()
            let history = Array(try store.piSessions().prefix(Self.historyLimit))
            return SidebarData(
                projects: try store.projects(),
                summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0) }),
                trashCount: try store.trashedProjects().count + store.trashedCards().count,
                history: history,
                historyProjects: try Dictionary(uniqueKeysWithValues: history.compactMap { session in
                    try store.project(containing: URL(filePath: session.cwd)).map { (session.id, $0.id) }
                }))
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

    private func row(_ project: Project, _ data: SidebarData) -> some View {
        PageRow(page: .project(project.id), count: data.summaries[project.id]?.cardCount ?? 0, select: select) {
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
            // 空库首次打开先让人建项目，连接 Pi 的提示等有了项目再出现
            if data?.projects.isEmpty == false { ExtensionConsent() }
            StartupIssues()
            HStack {
                Button("新建项目", systemImage: "plus") { creating = true }
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
    }
}

/// 侧栏里能去的页，按显示顺序：置顶项目 → 最近项目 → 未归档 → 回收站。分组显示与方向键共用这一份顺序。
private struct SidebarPages {
    let pinned: [Project]
    let recent: [Project]
    let inboxCount: Int
    let showsTrash: Bool

    init(_ data: SidebarData) {
        let ordered = SidebarOrder.projects(data.projects, summaries: Array(data.summaries.values))
        pinned = ordered.filter(\.isPinned)
        recent = ordered.filter { !$0.isPinned }
        inboxCount = data.summaries[nil]?.cardCount ?? 0
        showsTrash = data.trashCount > 0 || !data.projects.isEmpty
    }

    var order: [Workspace.Page] {
        (pinned + recent).map { .project($0.id) } + (inboxCount > 0 ? [.inbox] : []) + (showsTrash ? [.trash] : [])
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

/// 全局 Pi：活着的会话（名称 · 所属项目 · 状态），其下是最近结束的历史会话。
private struct PiSection: View {
    let history: [StoredPiSession]
    let historyProjects: [String: UUID]
    let projects: [Project]
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let live = services.pi.sessions
        let liveIDs = Set(live.map(\.sessionID))
        let ended = history.filter { !liveIDs.contains($0.id) }
        if !live.isEmpty || !ended.isEmpty {
            Section("Pi") {
                ForEach(live) { session in
                    Button { jump(session) } label: {
                        HStack(spacing: 9) {
                            PiDot(state: session.state).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Workspace.sessionName(session)).lineLimit(1)
                                Text([projectName(workspace.sessionProjects[session.id]), session.state.label].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(session.state.labelColor(palette))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .help([session.state.detail, "点按跳到所在终端"].compactMap { $0 }.joined(separator: "\n"))
                }
                ForEach(ended) { session in
                    HStack(spacing: 9) {
                        PiDot(state: nil).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title.isEmpty ? URL(filePath: session.cwd).lastPathComponent : session.title)
                                .lineLimit(1)
                            Text([projectName(historyProjects[session.id]), DateLabel.short(session.lastActivityAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                }
            }
        }
    }

    private func projectName(_ id: UUID?) -> String? {
        id.flatMap { id in projects.first { $0.id == id }?.name }
    }

    private func jump(_ session: CuePi.PiSession) {
        Task {
            do {
                let result = try await services.jumpToTerminal(session.id)
                if let note = result.note { workspace.say(note, isError: result.precision == .failed) }
            } catch {
                workspace.fail(error)
            }
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
                Text("安装 CuePad 扩展后，这里能看到 Pi 会话的实时状态，并能把卡片直接发进会话。会写入 Pi 的扩展目录。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("不用了") { services.piExtension.decline() }
                    Button("安装") { install() }.buttonStyle(.borderedProminent).disabled(installing)
                }
                .controlSize(.small)
            }
            .padding(12)
            .paper(radius: 12)
            .padding(.horizontal, 10)
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
                        Text(StartupIssueText.describe(issue)).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
                .padding(14).frame(width: 340, alignment: .leading)
            }
        }
    }
}

enum StartupIssueText {
    static func describe(_ issue: AppServices.StartupIssue) -> String {
        switch issue {
        case .legacyImportFailed(let detail): "导入旧版数据失败，下次启动会重试：\(detail)"
        case .globalShortcutUnavailable(let detail): "全局快捷键没能注册，可在设置里换一个：\(detail)"
        case .piBridgeUnavailable(let detail): "Pi 连接不可用：\(detail)"
        case .piHistoryUnavailable(let detail): "Pi 历史索引出错：\(detail)"
        case .captureImportFailed(let detail): "分享进来的内容没能存成卡片，下次会重试：\(detail)"
        case .widgetDataUnavailable(let detail): "小组件数据没能更新：\(detail)"
        case .syncUnavailable(let detail): "iCloud 同步出了问题：\(detail)"
        }
    }
}
#endif
