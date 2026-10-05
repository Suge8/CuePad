#if os(iOS)
import CueStore
import SwiftUI

/// 新会话：选在哪开（项目的代码目录、最近会话用过的目录）、可选一句开场的话，请 Mac 在终端里开 Pi。
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
    @State private var prompt = ""
    @State private var launched: Navigation.NewSession.Launched?
    @State private var progress: LaunchProgress?
    @State private var sending = false

    private var chosen: LaunchPlace? { places?.first { $0.id == choice } ?? places?.first }
    /// 发出且还没失败：表单锁住，等它开好。
    private var inFlight: Bool { sending || (launched != nil && progress?.request?.status != .known(.failed)) }
    private var canStart: Bool { chosen != nil && services.reachesPiHost && !inFlight }

    var body: some View {
        NavigationStack {
            List {
                if inFlight, let request = progress?.request {
                    status(request)
                } else if let places {
                    if places.isEmpty {
                        ContentUnavailableView(
                            "还没有可以开会话的目录", systemImage: "folder",
                            description: Text("Mac 上跑过 pi，或项目的会话归入项目后，这里就有可选的目录"))
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
        .interactiveDismissDisabled(inFlight)
        .onAppear { if launched == nil { launched = start.launched } }
        .observing(services.store, [.piSessionStates, .projects], into: $places, onError: workspace.fail) { store in
            LaunchPlace.all(from: try store.piSessionPage(PiSessionQuery(limit: LaunchPlace.scanned)))
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
        Section("在哪开") {
            ForEach(places) { place in row(place) }
        }
        .disabled(inFlight)
        Section {
            TextField("开场的话（可不填）", text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .disabled(inFlight)
                .listRowBackground(palette.paper)
        } footer: {
            footer
        }
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
                    Text(place.project == nil ? "最近的会话在这里" : "项目的代码目录").font(.caption).foregroundStyle(palette.ink3)
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
                if case .start(_, let opening?, _) = request.launch {
                    Text(opening).font(.body).foregroundStyle(palette.ink2)
                }
                Text(request.status == .known(.succeeded) ? "Mac 正在终端里开 Pi，会话出现后自动进入" : "等 Mac 收到…")
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
            Text("在 Mac 的终端里开一个 Pi 会话；开好后自动进入它").foregroundStyle(palette.ink3)
        }
    }

    private func launch() {
        guard let place = chosen, canStart else { return }
        let token = UUID().uuidString
        let opening = prompt.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        sending = true
        workspace.attempt {
            defer { sending = false }
            let request = try await services.launch(.start(place.launch, prompt: opening, token: token), title: place.name, on: place.hostID)
            launched = .init(request: request.id, token: token)
        }
    }
}

/// 新会话可以开在哪：会话归入过的项目（Mac 按项目绑定的代码目录开；归入过说明那台 Mac 上绑定了），
/// 以及没归入项目的会话最近用过的几个文件夹（与那个会话同一目录开，按文件夹名去重）。都取最近的在前，`hostID` 是那台 Mac。
nonisolated struct LaunchPlace: Identifiable, Sendable, Equatable {
    /// 从最近这么多个会话里找；文件夹最多列这么多个。
    static let scanned = 100
    static let folderLimit = 5

    let id: String
    let name: String
    let project: Project?
    let launch: PiLaunchPlace
    let hostID: String

    static func all(from page: PiSessionPage) -> [LaunchPlace] {
        let items = page.items.sorted { $0.state.stateSince > $1.state.stateSince }
        var seen: Set<String> = []
        var projects: [LaunchPlace] = []
        var folders: [LaunchPlace] = []
        for item in items {
            if let project = item.project {
                guard seen.insert(project.id.uuidString).inserted else { continue }
                projects.append(LaunchPlace(
                    id: project.id.uuidString, name: project.name, project: project, launch: .project(project.id), hostID: item.state.hostID))
            } else if folders.count < folderLimit, let folder = item.state.folder, seen.insert("folder:" + folder).inserted {
                folders.append(LaunchPlace(
                    id: "folder:" + folder, name: folder, project: nil, launch: .besideSession(item.state.sessionID), hostID: item.state.hostID))
            }
        }
        return projects + folders
    }
}

/// 发出的新会话请求此刻的结果，以及认领到的会话（同步记录带着同一个标识）。
nonisolated struct LaunchProgress: Sendable, Equatable {
    var request: DeliveryRequest?
    var session: UUID?

    static func read(_ launched: Navigation.NewSession.Launched, from store: isolated CueStore) throws -> LaunchProgress {
        // 新开的会话没结束、进入当前状态最晚，排在第一页最前面
        let page = try store.piSessionPage(PiSessionQuery(limit: 20))
        return LaunchProgress(
            request: try store.deliveryRequest(launched.request),
            session: page.items.first { $0.state.launchToken == launched.token }?.id)
    }
}
#endif
