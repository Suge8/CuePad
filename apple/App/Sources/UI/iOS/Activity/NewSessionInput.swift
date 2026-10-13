#if os(iOS)
import CueStore
import SwiftUI

/// 新会话：只有一个浮在键盘上方的输入框，写的就是给 Pi 的第一句话；头部一颗落点胶囊"新会话 · 项目名"，点开换在哪开
/// （只列项目，默认 Agent 页正筛着的项目，没筛时是最近活跃的；项目绑在几台 Mac 上时菜单里写上 Mac 名），旁边一颗胶囊选用哪个 Agent 开
/// （列全部，默认上次用的 `AppSettings.lastAgent`；那台 Mac 没接入它时由 Mac 写回原因）。发送钮就是开始：
/// 发出后头部写进度（送达中 → Mac 在开），Mac 开好、带着这次标识的会话同步过来时自动收起并进入它；没能打开时头部写原因，可以再发。
/// 新会话的目录只由项目绑定的文件夹推出；选中还没绑文件夹的项目时头部引导就地绑（弹候选，请 Mac 绑），绑好才能开。
/// 没有项目时输入框换成一句说明。
struct NewSessionInput: View {
    let start: Navigation.NewSession
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var choice: ProjectFolders.LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    @State private var launched: Navigation.NewSession.Launched?
    @State private var progress: LaunchProgress?
    @State private var sending = false
    @FocusState private var focused: Bool

    /// 只列项目，按所有项目选择器的同一个顺序（`ProjectCatalog.projects`，最近活跃的在前）。
    private var places: [ProjectFolders.LaunchPlace] {
        ProjectFolders.launchPlaces(projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: nil)
    }
    private var chosen: ProjectFolders.LaunchPlace? {
        places.first { $0.id == choice } ?? start.project.flatMap { project in places.first { $0.project.id == project } } ?? places.first
    }
    private var phase: LaunchProgress.Phase { progress?.phase ?? .idle }
    /// 发出且还没失败：输入框锁住，等它开好。
    private var inFlight: Bool {
        if case .failed = phase { return sending }
        return sending || launched != nil
    }
    private var canStart: Bool { chosen?.binding != nil && services.reachesPiHost && !inFlight }

    var body: some View {
        Group {
            if places.isEmpty {
                Label("先新建一个项目，再给它选文件夹，就能在这里开会话", systemImage: "folder")
                    .font(.subheadline).foregroundStyle(palette.ink2)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .glass(in: .rect(cornerRadius: 25, style: .continuous))
            } else {
                Composer(
                    draft: $draft, prompt: "第一句话（可不填）", label: "新会话的第一句话", focus: $focused,
                    cardsFrom: chosen?.project.id, submitsEmpty: true,
                    header: {
                        header.padding(.horizontal, 12).padding(.top, 10)
                        status.font(.caption).lineLimit(2).padding(.horizontal, 18).padding(.top, 8)
                    },
                    tools: { EmptyView() },
                    send: {
                        Button(action: launch) { SubmitGlyph(.send, enabled: canStart) }
                            .buttonStyle(.plain).disabled(!canStart).accessibilityLabel("开始")
                    })
                .disabled(inFlight)
            }
        }
        // 浮在 `FloatingInput` 里（与随手记同一种）；发出后等它开好时不让收起
        .floatingInputLocked(inFlight)
        .onAppear {
            if launched == nil { launched = start.launched }
            if let seed = start.draft, draft.isEmpty(accepting: [.images, .cards]) { draft = seed }
            focused = true
        }
        .observing(services.store, id: launched, into: $progress, onError: workspace.fail) {
            [launched] store in
            guard let launched else { return LaunchProgress() }
            return try LaunchProgress.read(request: launched.request, token: launched.token, from: store)
        }
        .onChange(of: progress?.claimed?.id) { _, session in
            guard let session else { return }
            navigation.newSession = nil
            navigation.openSession(session, store: services.store)
        }
    }

    /// 头部：落点胶囊；进度或原因在它下面单独一行（放在右边会挤成两行、和胶囊对不齐）。
    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("在哪开", selection: Binding(get: { chosen?.id }, set: { choice = $0 })) {
                    ForEach(places) { place in
                        Text(Dotted(place.project.name, place.detail ?? (place.binding == nil ? "还没有文件夹" : nil)))
                            .tag(Optional(place.id))
                    }
                }
            } label: {
                DestinationChip(title: Text(Dotted("新会话", chosen?.project.name ?? "选在哪开"))) {
                    if let project = chosen?.project { ProjectGlyph(project: project, size: 13) }
                }
            }
            .disabled(inFlight)
            .accessibilityLabel("在哪开：\(chosen?.project.name ?? "没选")")
            Menu {
                Picker("用哪个 Agent", selection: Bindable(services.settings).lastAgent) {
                    ForEach(AgentKind.allCases) { Text($0.name).tag($0) }
                }
            } label: {
                DestinationChip(title: Text(services.settings.lastAgent.name)) { EmptyView() }
            }
            .disabled(inFlight)
            .accessibilityLabel("用哪个 Agent：\(services.settings.lastAgent.name)")
            Spacer(minLength: 0)
        }
    }

    /// 发出后的进度，上一次没能打开的原因，送不到 Mac 的原因，或项目还没有文件夹时的引导。
    @ViewBuilder private var status: some View {
        if let place = chosen, place.binding == nil, phase == .idle {
            // 项目还没有文件夹：写明，同名文件夹一键绑，或自己选（请 Mac 绑，进度与没绑成的原因就在这里）
            VStack(alignment: .leading, spacing: 0) {
                Text("「\(place.project.name)」还没有文件夹").foregroundStyle(palette.ink3)
                ProjectFolderGuide(project: place.project, guide: workspace.folderGuide, style: .line)
            }
        } else {
            switch phase {
            case .failed(let reason): Text(reason).foregroundStyle(palette.failure)
            case .opening, .claimed: Text("Mac 正在开 Agent 会话…").foregroundStyle(palette.ink3)
            case .sending(let request): DeliveryStatusLabel(request: request)
            case .idle: if !services.reachesPiHost { SyncHint(status: services.syncStatus, consequence: "发不到 Mac") }
            }
        }
    }

    private func launch() {
        guard let place = chosen, let binding = place.binding, canStart else { return }
        let token = UUID().uuidString
        let draft = draft
        sending = true
        workspace.attempt {
            defer { sending = false }
            let opening = try draft.stored(in: services.store.files).nonEmpty
            // 从提示词"新会话"发给 Agent：开好后它关联到这个会话（带着的那一条）
            let request = try await services.launch(
                PiLaunch(project: place.project.id, prompt: opening, token: token, agent: services.settings.lastAgent), title: place.project.name, on: binding.hostID,
                card: start.card ?? draft.attachments.first?.card)
            launched = .init(request: request.id, token: token)
        }
    }
}
#endif
