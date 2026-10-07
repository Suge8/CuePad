#if os(macOS)
import CueStore
import SwiftUI

/// Pi 分组标题旁的 +：在本机后台开一个新会话；开好后关掉表单、打开新会话的详情。
struct NewSessionButton: View {
    /// 侧栏读到的会话（取没绑项目的最近目录）。
    let recent: [PiSessionState]
    @Binding var showing: Bool
    @Environment(\.sessionDetail) private var sessionDetail
    /// 新会话出现后先关表单，表单真正消失后再打开详情（两个弹出层不同时出现）。
    @State private var opened: String?

    var body: some View {
        Button("新会话", systemImage: "plus") { showing = true }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .help("开一个新的 Agent 会话")
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                NewSessionForm(recent: recent) { id in
                    guard showing else { return sessionDetail?.open(id) ?? () }
                    opened = id
                    showing = false
                }
                .onDisappear {
                    if let opened { sessionDetail?.open(opened) }
                    opened = nil
                }
            }
    }
}

/// 新会话开在哪：项目绑定的代码目录，或最近会话用过、没绑项目的目录（与那个会话同一目录）。
private struct LaunchPlace: Identifiable {
    let id: String
    let place: PiLaunchPlace
    let title: String
    let project: Project?
    /// 第二行：目录名或"和「会话名」同一目录"。
    let detail: String

    static func all(catalog: ProjectCatalog?, recent: [PiSessionState]) -> [LaunchPlace] {
        let projects = (catalog?.projects ?? []).compactMap { project -> LaunchPlace? in
            guard let directory = catalog?.directories[project.id] else { return nil }
            return LaunchPlace(
                id: "project-\(project.id)", place: .project(project.id), title: project.name, project: project,
                detail: URL(filePath: directory).lastPathComponent)
        }
        var folders = Set<String>()
        let others = recent.compactMap { session -> LaunchPlace? in
            guard session.projectID == nil, let folder = session.folder, folders.insert(folder).inserted else { return nil }
            return LaunchPlace(
                id: "beside-\(session.sessionID)", place: .besideSession(session.sessionID), title: folder, project: nil,
                detail: "和「\(session.title)」同一目录")
        }
        return projects + others
    }
}

private struct NewSessionForm: View {
    let recent: [PiSessionState]
    let opened: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var chosen: String?
    @State private var prompt = ""
    @State private var stage = Stage.idle

    private enum Stage: Equatable {
        case idle
        /// 请求发出，等这台 Mac 启动 Pi。
        case opening
        /// Pi 已启动，等它连上（连上后表单关掉、打开新会话）。
        case connecting
        case failed(String)
    }

    private static let width: CGFloat = 340
    private static let listHeight: CGFloat = 240

    var body: some View {
        let places = LaunchPlace.all(catalog: workspace.catalog, recent: recent)
        // 没选过时默认当前项目（有代码目录的话）
        let place = places.first { $0.id == chosen }
            ?? places.first { $0.project != nil && $0.project?.id == workspace.currentProject } ?? places.first
        VStack(alignment: .leading, spacing: 12) {
            Text("新会话").font(.headline).foregroundStyle(palette.ink)
            if places.isEmpty {
                Text("还没有可以开会话的目录：给项目绑定代码目录，或先运行一次 pi。")
                    .font(.callout).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(places) { row($0, selected: $0.id == place?.id) } }
                }
                .frame(maxHeight: Self.listHeight).fixedSize(horizontal: false, vertical: true)
                TextField("开场的话（可不填）", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .paper(radius: 10)
                    .accessibilityLabel("开场的话")
            }
            HStack(spacing: 8) {
                switch stage {
                case .idle:
                    Text("在后台开，不占终端").font(.footnote).foregroundStyle(palette.ink3)
                case .opening:
                    ProgressView().controlSize(.small)
                    Text("正在开…").font(.footnote).foregroundStyle(palette.ink3)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("等 Agent 连上…").font(.footnote).foregroundStyle(palette.ink3)
                case .failed(let reason):
                    Text(reason).font(.footnote).foregroundStyle(palette.failure).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("开始") { place.map(start) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(place == nil || stage == .opening)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: Self.width)
    }

    private func row(_ place: LaunchPlace, selected: Bool) -> some View {
        Button { chosen = place.id } label: {
            HStack(spacing: 8) {
                if let project = place.project {
                    ProjectGlyph(project: project, size: 13)
                } else {
                    Image(systemName: "folder").foregroundStyle(palette.ink3).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.title).foregroundStyle(palette.ink).lineLimit(1)
                    Text(place.detail).font(.caption).foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(palette.ink2).accessibilityHidden(true) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func start(_ place: LaunchPlace) {
        stage = .opening
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let id = try await workspace.startSession(
                    at: place.place, prompt: words.isEmpty ? nil : words, title: place.title) { stage = .connecting }
                stage = .idle
                opened(id)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
