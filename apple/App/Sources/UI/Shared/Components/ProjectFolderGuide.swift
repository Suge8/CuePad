import CueStore
import SwiftUI

/// 项目还没有文件夹时，"这个项目的 Agent"处的引导（iOS 与 Mac 共用）：Agent 会话按工作目录归入项目，没绑文件夹就一个会话也归不进来。
/// 已有会话的文件夹与项目同名（忽略大小写）时直接给一键"绑定 <文件夹> · N 个会话"，有几个列几个让人选（规则 `ProjectFolders.suggestions`），
/// 点了走同一条绑定通路（`PiBind` 请求让那台 Mac 绑；Mac 上是本机）；另有"选文件夹…"自己挑。绑好之后已有会话立即归进项目。
/// 请求的进度与没绑成的原因读投送请求（`ProjectFolders.bindProgress`），写在建议上面。
struct ProjectFolderGuide: View {
    enum Style {
        /// 空态页里（Agent 页筛着这个项目）：标题与说明由空态写，这里只有按钮——第一个建议是主按钮，其余与"选文件夹…"是次要的。
        case page
        /// 项目页里自成一小块纸：文件夹图标、一句"绑定文件夹，看这个项目的 Agent 会话"、下面一排按钮。
        case panel
        /// 同上但不自带纸（放进已有的纸里：Mac 项目页的 Agent 栏、iPhone 项目卡的 Agent 段）。
        case inset
        /// 一排小按钮（新会话输入框的头部；说明由调用方写）。
        case line
    }

    let project: Project
    var style = Style.page
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var guide: FolderGuide?

    var body: some View {
        Group {
            switch style {
            case .page: actions.multilineTextAlignment(.center)
            case .panel: block.padding(14).paper(radius: 16)
            case .inset: block
            case .line: actions
            }
        }
        .observingFolderGuide(into: $guide)
    }

    private var progress: ProjectFolders.BindProgress? { guide.flatMap { ProjectFolders.bindProgress(of: project.id, in: $0.requests) } }
    private var suggestions: [ProjectFolders.Candidate] { guide?.suggestions[project.id] ?? [] }

    /// 图标 + 一句说明，下面是进度或按钮。
    private var block: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: Self.iconSize, weight: .medium)).foregroundStyle(palette.ink2)
                .frame(width: Self.tile, height: Self.tile)
                .background(palette.fill, in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("绑定文件夹，看这个项目的 Agent 会话").font(Self.titleFont).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 进度或没绑成的原因在上；按钮：第一个建议是唯一带签名色的那颗（空态页是实心主按钮，其余地方是浅底的强调钮），
    /// 其余建议与"选文件夹…"是次要的。没有同名建议时"选文件夹…"就是那一颗。
    @ViewBuilder private var actions: some View {
        let progress = progress, suggestions = suggestions
        let showsMac = Set(suggestions.map(\.hostID)).count > 1
        VStack(alignment: style == .page ? .center : .leading, spacing: style == .page ? 10 : 6) {
            switch progress {
            case .binding:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Mac 正在绑定文件夹…").foregroundStyle(palette.ink3)
                }
                .font(Self.noteFont)
            case .failed(let reason):
                Text("没绑成：\(reason)").font(Self.noteFont).foregroundStyle(palette.failure).fixedSize(horizontal: false, vertical: true)
            case nil: EmptyView()
            }
            if progress != .binding {
                buttons(first: suggestions.first, others: Array(suggestions.dropFirst()), showsMac: showsMac)
            }
        }
    }

    @ViewBuilder
    private func buttons(first: ProjectFolders.Candidate?, others: [ProjectFolders.Candidate], showsMac: Bool) -> some View {
        let choose = Button("选文件夹…") { workspace.chooseFolder(for: project) }
        if style == .page {
            if let first { suggestion(first, showsMac: showsMac).modifier(GuideButton(kind: .solid)) }
            ForEach(others, id: \.id) { suggestion($0, showsMac: showsMac).modifier(GuideButton(kind: .plain)) }
            choose.modifier(GuideButton(kind: first == nil ? .solid : .plain))
        } else {
            // 主次同一排：一键绑在前、"选文件夹…"跟在后面；多出来的建议各占一行、次要样式
            HStack(spacing: 8) {
                if let first { suggestion(first, showsMac: showsMac).modifier(GuideButton(kind: .soft)) }
                choose.modifier(GuideButton(kind: first == nil ? .soft : .plain))
            }
            ForEach(others, id: \.id) { suggestion($0, showsMac: showsMac).modifier(GuideButton(kind: .plain)) }
        }
    }

    private func suggestion(_ candidate: ProjectFolders.Candidate, showsMac: Bool) -> some View {
        Button(ProjectFolders.suggestionTitle(candidate, showsMac: showsMac)) { bind(candidate) }
            .accessibilityHint("让\(candidate.hostName ?? "那台 Mac")把这个文件夹绑给「\(project.name)」")
    }

    private func bind(_ candidate: ProjectFolders.Candidate) {
        let id = project.id, name = project.name
        workspace.attempt { try await workspace.requestFolder(PiBind(project: id, folder: candidate.target), title: name, on: candidate.hostID) }
    }

    #if os(iOS)
    private static let tile: CGFloat = 32, iconSize: CGFloat = 15
    private static let titleFont = Typography.secondary.weight(.medium), noteFont = Typography.meta
    #else
    private static let tile: CGFloat = 26, iconSize: CGFloat = 12
    private static let titleFont = Typography.secondary.weight(.medium), noteFont = Typography.meta
    #endif
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

/// 引导里的按钮：实心主按钮（空态页的第一个建议）、浅底强调钮（签名色字垫选中底，其余地方的那一颗）、次要的墨色字。
/// 高矮一致（iOS 点得到 44），同一排里底边对齐。
private struct GuideButton: ViewModifier {
    enum Kind { case solid, soft, plain }
    let kind: Kind
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        switch kind {
        case .solid:
            #if os(iOS)
            content.prominentButton().controlSize(.large)
            #else
            content.buttonStyle(.borderedProminent).tint(palette.signature).controlSize(.large)
            #endif
        case .soft:
            content.buttonStyle(.plain).font(Self.font).foregroundStyle(palette.signature).lineLimit(1)
                .padding(.horizontal, 12).frame(height: Self.height)
                .background(palette.selection, in: .capsule)
                .contentShape(.capsule)
                .padding(.vertical, Self.hitPadding)
        case .plain:
            content.buttonStyle(.plain).font(Self.font).foregroundStyle(palette.ink2).lineLimit(1)
                .padding(.horizontal, 4).frame(height: Self.height)
                .contentShape(.rect)
                .padding(.vertical, Self.hitPadding)
        }
    }

    #if os(iOS)
    private static let font = Font.subheadline.weight(.medium), height: CGFloat = 34, hitPadding: CGFloat = 5
    #else
    private static let font = Typography.secondary.weight(.medium), height: CGFloat = 28, hitPadding: CGFloat = 0
    #endif
}
