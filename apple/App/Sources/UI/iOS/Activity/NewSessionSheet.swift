#if os(iOS)
import CueStore
import SwiftUI

/// 新会话：选在哪开（项目的代码目录、最近会话用过的目录）、可选一句开场的话，请 Mac 在后台开 Pi。
/// 发出后面板换成进度（送达中 → Mac 在开）；Mac 开好、带着这次标识的会话同步过来时自动关掉并进入它；
/// 没能打开时回到表单，写着 Mac 给的原因，可以再试。
struct NewSessionSheet: View {
    let start: Navigation.NewSession
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var places: [LaunchPlace]?
    @State private var choice: LaunchPlace.ID?
    @State private var draft = ComposerDraft()
    @State private var launched: Navigation.NewSession.Launched?
    @State private var progress: LaunchProgress?
    @State private var sending = false
    @FocusState private var focused: Bool

    /// 项目按所有项目选择器的同一个顺序（`ProjectCatalog.projects`）。
    private var projectOrder: [Project] { workspace.catalog?.projects ?? [] }
    private var chosen: LaunchPlace? {
        places?.first { $0.id == choice } ?? places?.first { $0.project?.id == start.project } ?? places?.first
    }
    /// 发出且还没失败：表单锁住，等它开好。
    private var inFlight: Bool { sending || (launched != nil && progress?.request?.status != .known(.failed)) }
    private var canStart: Bool { chosen != nil && services.reachesPiHost && !inFlight }
    private var showsComposer: Bool { !inFlight && places?.isEmpty == false }

    var body: some View {
        NavigationStack {
            List {
                if inFlight, let request = progress?.request {
                    status(request)
                } else if let places {
                    if places.isEmpty {
                        ContentUnavailableView(
                            "还没有可以开会话的目录", systemImage: "folder",
                            description: Text("在 Mac 上给项目绑定代码目录，或在 Mac 上跑过 pi 后，这里就有可选的目录"))
                            .listRowBackground(Color.clear)
                    } else {
                        form(places)
                    }
                }
            }
            .deskBackground()
            .navigationTitle("新会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始", systemImage: "arrow.up", action: launch).disabled(!canStart)
                }
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if showsComposer {
                // 开场的话与回复框是同一个输入框：只是没有发送钮，开始在右上角
                Composer(draft: $draft, prompt: "开场的话（可不填）", label: "开场的话", focus: $focused, cardsFrom: chosen?.project?.id) {
                    EmptyView()
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .interactiveDismissDisabled(inFlight)
        .onAppear { if launched == nil { launched = start.launched } }
        .observing(services.store, [.directoryBindings, .piSessionStates], id: projectOrder, into: $places, onError: workspace.fail) {
            [projectOrder] store in try LaunchPlace.all(projects: projectOrder, from: store)
        }
        .observing(services.store, [.deliveryRequests, .piSessionStates], id: launched, into: $progress, onError: workspace.fail) {
            [launched] store in
            guard let launched else { return LaunchProgress() }
            return try LaunchProgress.read(launched, from: store)
        }
        .onChange(of: progress?.session) { _, session in
            guard let session else { return }
            dismiss()
            navigation.openSession(session)
        }
    }

    @ViewBuilder private func form(_ places: [LaunchPlace]) -> some View {
        Section {
            ForEach(places) { place in row(place) }
        } header: {
            Text("在哪开")
        } footer: {
            footer
        }
        .disabled(inFlight)
    }

    private func row(_ place: LaunchPlace) -> some View {
        Button { choice = place.id } label: {
            HStack(spacing: 12) {
                if let project = place.project {
                    ProjectGlyph(project: project, size: 15)
                } else {
                    Image(systemName: "folder").foregroundStyle(palette.ink3).frame(width: 21).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                    Text(place.detail).font(.caption).foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if chosen?.id == place.id {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
        .accessibilityAddTraits(chosen?.id == place.id ? .isSelected : [])
    }

    /// 发出后：开在哪、开场的话、送达情况（送达中 → Mac 在开，会话出现后自动进入）。
    private func status(_ request: DeliveryRequest) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(request.target.name).font(.headline).foregroundStyle(palette.ink)
                    Spacer(minLength: 8)
                    DeliveryStatusLabel(request: request)
                }
                if let opening = request.launch?.prompt {
                    Text(SendContent(stored: opening).plainText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body).foregroundStyle(palette.ink2).lineLimit(4)
                }
                Text(request.status == .known(.succeeded) ? "Mac 正在开 Pi，会话出现后自动进入" : "等 Mac 收到…")
                    .font(.footnote).foregroundStyle(palette.ink3)
            }
            .padding(.vertical, 6)
            .listRowBackground(palette.paper)
        }
    }

    /// 上一次没能打开的原因（Mac 给的），或送不到 Mac 的原因。
    @ViewBuilder private var footer: some View {
        if let request = progress?.request, request.status == .known(.failed) {
            Text(request.resultDetail ?? "没能打开").foregroundStyle(palette.failure)
        } else if !services.reachesPiHost {
            SyncHint(status: services.syncStatus)
        } else {
            Text("让 Mac 开一个 Pi 会话；开好后自动进入它").foregroundStyle(palette.ink3)
        }
    }

    private func launch() {
        guard let place = chosen, canStart else { return }
        let token = UUID().uuidString
        let draft = draft
        sending = true
        workspace.attempt {
            defer { sending = false }
            let opening = try draft.stored(in: services.store.files).nonEmpty
            let request = try await services.launch(PiLaunch(place: place.launch, prompt: opening, token: token), title: place.name, on: place.hostID)
            launched = .init(request: request.id, token: token)
        }
    }
}

/// 新会话可以开在哪：绑定了代码目录的项目（每个项目 + Mac 一项，发给绑定它的那台 Mac；同一项目绑在几台 Mac 上时
/// 写上 Mac 名让人选），以及没归入项目的会话最近用过的几个文件夹（与那个会话同一目录开、发给那个会话的 Mac，按文件夹名去重）。
nonisolated struct LaunchPlace: Identifiable, Sendable, Equatable {
    /// 文件夹最多列这么多个，从最近这么多个已结束的会话里找。
    static let folderLimit = 5
    static let scanned = 100

    let id: String
    let name: String
    /// 名字下的一行：目录名，必要时加 Mac 名。
    let detail: String
    let project: Project?
    let launch: PiLaunchPlace
    let hostID: String

    /// `projects` 是界面的项目顺序；同一项目的几台 Mac 按查询给的顺序（Mac 名）。
    static func all(projects: [Project], from store: isolated CueStore) throws -> [LaunchPlace] {
        let bindings = Dictionary(grouping: try store.directoryBindings(), by: \.projectID)
        let bound = projects.flatMap { project in
            let macs = bindings[project.id] ?? []
            return macs.map { binding in
                LaunchPlace(
                    id: binding.id.uuidString, name: project.name,
                    detail: macs.count > 1 ? "\(binding.folder) · \(binding.hostName)" : binding.folder,
                    project: project, launch: .project(project.id), hostID: binding.hostID)
            }
        }
        var seen: Set<String> = []
        var folders: [LaunchPlace] = []
        for item in try store.piSessionPage(PiSessionQuery(limit: scanned)).items where item.project == nil {
            guard folders.count < folderLimit, let folder = item.state.folder, seen.insert(folder).inserted else { continue }
            folders.append(LaunchPlace(
                id: "folder:" + folder, name: folder, detail: "最近的会话在这里", project: nil,
                launch: .besideSession(item.state.sessionID), hostID: item.state.hostID))
        }
        return bound + folders
    }
}

/// 发出的新会话请求此刻的结果，以及认领到的会话（同步记录带着同一个标识）。
nonisolated struct LaunchProgress: Sendable, Equatable {
    var request: DeliveryRequest?
    var session: UUID?

    static func read(_ launched: Navigation.NewSession.Launched, from store: isolated CueStore) throws -> LaunchProgress {
        LaunchProgress(
            request: try store.deliveryRequest(launched.request),
            session: try store.piSessionPage(PiSessionQuery(launchToken: launched.token)).items.first?.id)
    }
}
#endif
