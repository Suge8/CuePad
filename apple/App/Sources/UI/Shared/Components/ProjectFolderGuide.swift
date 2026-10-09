import CueStore
import SwiftUI

/// 项目还没有文件夹时，"这个项目的 Agent"处的引导（iOS 与 Mac 共用）：Agent 会话按工作目录归入项目，没绑文件夹就一个会话也归不进来。
/// 已有会话的文件夹与项目同名（忽略大小写）时直接给一键"绑定 <文件夹> 文件夹（N 个会话）"，有几个列几个让人选（规则 `ProjectFolders.suggestions`），
/// 点了走同一条绑定通路（`PiBind` 请求让那台 Mac 绑；Mac 上是本机）；另有"选文件夹…"自己挑。绑好之后已有会话立即归进项目。
/// 请求的进度与没绑成的原因读投送请求（`ProjectFolders.bindProgress`），写在建议上面。
struct ProjectFolderGuide: View {
    enum Style {
        /// 空态页里：建议是整宽按钮（第一个主钮），下面是"选文件夹…"。
        case page
        /// 一行行的小字（栏里、输入框头部）。
        case line
    }

    let project: Project
    var style = Style.page
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var guide: FolderGuide?

    var body: some View {
        let progress = guide.flatMap { ProjectFolders.bindProgress(of: project.id, in: $0.requests) }
        let suggestions = guide?.suggestions[project.id] ?? []
        let showsMac = Set(suggestions.map(\.hostID)).count > 1
        VStack(alignment: style == .page ? .center : .leading, spacing: style == .page ? 12 : 4) {
            switch progress {
            case .binding:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Mac 正在绑定文件夹…").foregroundStyle(palette.ink3)
                }
                .font(.footnote)
            case .failed(let reason):
                Text("没绑成：\(reason)").font(.footnote).foregroundStyle(palette.failure).fixedSize(horizontal: false, vertical: true)
            case nil: EmptyView()
            }
            if progress != .binding {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, candidate in
                    Button(ProjectFolders.suggestionTitle(candidate, showsMac: showsMac)) { bind(candidate) }
                        .accessibilityHint("让\(candidate.hostName ?? "那台 Mac")把这个文件夹绑给「\(project.name)」")
                        .modifier(GuideButton(style: style, prominent: style == .page && index == 0))
                }
                Button("选文件夹…") { workspace.chooseFolder(for: project) }
                    .modifier(GuideButton(style: style, prominent: false))
            }
        }
        .multilineTextAlignment(style == .page ? .center : .leading)
        .observingFolderGuide(into: $guide)
    }

    private func bind(_ candidate: ProjectFolders.Candidate) {
        let id = project.id, name = project.name
        workspace.attempt { try await workspace.requestFolder(PiBind(project: id, folder: candidate.target), title: name, on: candidate.hostID) }
    }
}

/// 引导读到的数据：各个还没有文件夹的项目的同名建议，与绑定请求。
nonisolated struct FolderGuide: Sendable, Equatable {
    var suggestions: [UUID: [ProjectFolders.Candidate]]
    var requests: [DeliveryRequest]

    static let tables: Set<StoreTable> = [.piSessionStates, .directoryBindings, .projects, .deliveryRequests]

    /// `host` 是 Mac 上本机的标识：Mac 上只建议本机的文件夹；手机传 nil，看全部 Mac 的。
    static func read(host: String?, from store: isolated CueStore) throws -> FolderGuide {
        let projects = try store.projects(), bindings = try store.directoryBindings(), folders = try store.sessionFolders()
        var suggestions: [UUID: [ProjectFolders.Candidate]] = [:]
        for project in projects where !ProjectFolders.isBound(project.id, bindings: bindings, host: host) {
            let candidates = ProjectFolders.candidates(folders: folders, bindings: bindings, projects: projects, excluding: project.id)
            let named = ProjectFolders.suggestions(for: project, in: candidates.filter { host == nil || $0.hostID == host })
            if !named.isEmpty { suggestions[project.id] = named }
        }
        return FolderGuide(suggestions: suggestions, requests: try store.deliveryRequests().filter { $0.mode == .known(.bind) })
    }
}

extension View {
    /// 跟着会话、目录绑定、项目与绑定请求读 `FolderGuide`。
    func observingFolderGuide(into guide: Binding<FolderGuide?>) -> some View { modifier(FolderGuideObserver(guide: guide)) }
}

private struct FolderGuideObserver: ViewModifier {
    @Binding var guide: FolderGuide?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content.observing(services.store, FolderGuide.tables, into: $guide, onError: workspace.fail) { [host = workspace.localHost] store in
            try FolderGuide.read(host: host, from: store)
        }
    }
}

private struct GuideButton: ViewModifier {
    let style: ProjectFolderGuide.Style
    let prominent: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        switch style {
        case .page:
            #if os(iOS)
            if prominent { content.prominentButton().controlSize(.large) } else { content.buttonStyle(.plain).foregroundStyle(palette.ink2).frame(minHeight: 44) }
            #else
            if prominent { content.buttonStyle(.borderedProminent).controlSize(.large) } else { content.buttonStyle(.link).controlSize(.regular) }
            #endif
        case .line:
            content.buttonStyle(.plain).font(.footnote.weight(.medium)).foregroundStyle(palette.signature)
                .multilineTextAlignment(.leading)
                #if os(iOS)
                .frame(minHeight: 44, alignment: .leading)
                #endif
        }
    }
}
