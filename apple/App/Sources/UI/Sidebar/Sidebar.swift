#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 侧栏的项目顺序：置顶的按手动顺序在前，其余按最近修改。⌘1–9 按这个顺序。
nonisolated enum SidebarOrder {
    static func projects(_ projects: [Project], summaries: [ProjectSummary]) -> [Project] {
        let latest = Dictionary(uniqueKeysWithValues: summaries.compactMap { s in s.projectID.map { ($0, s.lastModifiedAt ?? .distantPast) } })
        let recent = projects.filter { !$0.isPinned }.sorted {
            let a = latest[$0.id] ?? $0.modifiedAt, b = latest[$1.id] ?? $1.modifiedAt
            return a != b ? a > b : $0.sortKey < $1.sortKey
        }
        return projects.filter(\.isPinned) + recent
    }
}

nonisolated private struct SidebarData: Sendable {
    var projects: [Project]
    var summaries: [UUID?: ProjectSummary]
    var trashCount: Int
    var history: [StoredPiSession]
}

struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var data: SidebarData?
    @State private var creating = false
    @State private var renaming: Project?

    nonisolated private static let historyLimit = 5

    var body: some View {
        List(selection: selection) {
            if let data {
                let ordered = SidebarOrder.projects(data.projects, summaries: Array(data.summaries.values))
                let pinned = ordered.filter(\.isPinned)
                if !pinned.isEmpty {
                    Section("置顶") { ForEach(pinned) { row($0, data) } }
                }
                Section("最近") {
                    ForEach(ordered.filter { !$0.isPinned }) { row($0, data) }
                    if let inbox = data.summaries[nil], inbox.cardCount > 0 {
                        Label("未归档", systemImage: "tray")
                            .badge(inbox.cardCount)
                            .tag(Workspace.Page.inbox)
                    }
                }
                PiSection(history: data.history, projects: data.projects)
                Section {
                    Label("回收站", systemImage: "trash")
                        .badge(data.trashCount)
                        .tag(Workspace.Page.trash)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(isPresented: $creating) { ProjectForm(project: nil) }
        .sheet(item: $renaming) { ProjectForm(project: $0) }
        .observing(services.store, [.projects, .cards, .piSessions], into: $data, onError: workspace.fail) { store in
            let summaries = try store.projectSummaries()
            return SidebarData(
                projects: try store.projects(),
                summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0) }),
                trashCount: try store.trashedProjects().count + store.trashedCards().count,
                history: Array(try store.piSessions().prefix(Self.historyLimit)))
        }
    }

    private var selection: Binding<Workspace.Page?> {
        Binding(get: { workspace.page }, set: { if let page = $0 { workspace.show(page) } })
    }

    private func row(_ project: Project, _ data: SidebarData) -> some View {
        Label {
            Text(project.name)
        } icon: {
            ProjectGlyph(project: project)
        }
        .badge(data.summaries[project.id]?.cardCount ?? 0)
        .tag(Workspace.Page.project(project.id))
        .contextMenu { ProjectMenu(project: project, rename: { renaming = project }) }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            ExtensionConsent()
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

/// 全局 Pi：活着的会话（名称 · 所属项目 · 状态），其下是最近结束的历史会话。
private struct PiSection: View {
    let history: [StoredPiSession]
    let projects: [Project]
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

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
                                Text([projectName(session.cwd.path), session.state.label].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help([session.state.detail, "点按跳到所在终端"].compactMap { $0 }.joined(separator: "\n"))
                }
                ForEach(ended) { session in
                    HStack(spacing: 9) {
                        PiDot(state: nil).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title.isEmpty ? URL(filePath: session.cwd).lastPathComponent : session.title)
                                .lineLimit(1)
                            Text([projectName(session.cwd), DateLabel.short(session.lastActivityAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                }
            }
        }
    }

    private func projectName(_ cwd: String) -> String? {
        guard let directories = workspace.directories,
              let id = PiProjectMatch.project(forDirectory: cwd, in: directories)
        else { return nil }
        return projects.first { $0.id == id }?.name
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
    @State private var showing = false

    var body: some View {
        if !services.startupIssues.isEmpty {
            Button {
                showing.toggle()
            } label: {
                Label("\(services.startupIssues.count) 个启动问题", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
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
