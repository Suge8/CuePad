import CueStore
import Foundation

/// 项目与文件夹的规则（iOS 与 Mac 共用）。绑定是 Mac 本机的事（`CueStore.setDirectory`，路径因设备而异）；
/// 手机能看到的只有各 Mac 同步来的目录绑定（`DirectoryBinding`：Mac 名与文件夹名），要绑时经投送请求（`PiBind`）让那台 Mac 解析成完整路径。
nonisolated enum ProjectFolders {
    /// 新会话可以开在哪：每个项目一项，按项目的顺序（`ProjectCatalog.projects`）；没绑文件夹的也列（`binding` 为 nil，选中时就地引导去绑）；
    /// 同一项目绑在几台 Mac 上时每台一项（手机选发给哪台 Mac，`detail` 写 Mac 名）。
    struct LaunchPlace: Identifiable, Equatable, Sendable {
        let id: String
        let project: Project
        let binding: DirectoryBinding?
        let detail: String?
    }

    /// `host` 是 Mac 上本机的标识：新会话只在本机开，只认本机的绑定；手机传 nil，看全部。
    static func launchPlaces(projects: [Project], bindings: [DirectoryBinding], host: String?) -> [LaunchPlace] {
        projects.flatMap { project -> [LaunchPlace] in
            let own = bindings.filter { $0.projectID == project.id && (host == nil || $0.hostID == host) }
            guard !own.isEmpty else { return [LaunchPlace(id: project.id.uuidString, project: project, binding: nil, detail: nil)] }
            return own.map { binding in
                LaunchPlace(
                    id: binding.id.uuidString, project: project, binding: binding, detail: own.count > 1 ? binding.hostName : nil)
            }
        }
    }

    /// 项目操作菜单里的绑定项（`ProjectActions`）：没绑是"绑定文件夹…"，绑了是"换文件夹…"加解除；
    /// Mac 上只管本机的绑定，手机上管全部，绑在几台 Mac 上时解除按 Mac 分开。
    struct Menu: Equatable {
        struct Unbind: Equatable {
            let title: String
            let binding: DirectoryBinding
        }

        let bindTitle: String
        let unbinds: [Unbind]
    }

    static func menu(for project: UUID, bindings: [DirectoryBinding], host: String?) -> Menu {
        let own = bindings.filter { $0.projectID == project && (host == nil || $0.hostID == host) }
        return Menu(
            bindTitle: own.isEmpty ? "绑定文件夹…" : "换文件夹…",
            unbinds: own.map { Menu.Unbind(title: own.count > 1 ? "解除绑定 · \($0.hostName)" : "解除绑定", binding: $0) })
    }

    /// 手机上给项目选文件夹的一个候选：Mac 上已知的一个文件夹（只有名字）与"让那台 Mac 从哪里取"。
    struct Candidate: Identifiable, Equatable, Sendable {
        var id: String { "\(hostID)/\(folder)" }
        let hostID: String
        /// 那台 Mac 的名字；Mac 还没写过目录绑定时不知道。
        let hostName: String?
        let folder: String
        let target: PiFolder
        /// 已经是哪个项目在用（会话归的项目，或绑着它的项目）。
        let usedBy: String?
    }

    /// 候选来自同步来的现成数据：各 Mac 上跑过 Agent 的文件夹（会话记录，最近的在前），其次是别的项目绑着、但没有会话跑过的文件夹；
    /// 同一台 Mac 上同名的只列一个（手机分不出同名的两个文件夹）；`excluding` 项目在那台 Mac 上已绑着的不再列。
    static func candidates(sessions: [PiSessionListItem], bindings: [DirectoryBinding], projects: [Project], excluding project: UUID?) -> [Candidate] {
        let names = Dictionary(bindings.map { ($0.hostID, $0.hostName) }, uniquingKeysWith: { first, _ in first })
        let own = Set(bindings.filter { $0.projectID == project }.map { "\($0.hostID)/\($0.folder)" })
        let owners = Dictionary(
            bindings.filter { $0.projectID != project }.compactMap { binding in
                projects.first { $0.id == binding.projectID }.map { ("\(binding.hostID)/\(binding.folder)", $0.name) }
            }, uniquingKeysWith: { first, _ in first })
        var seen = own
        var result: [Candidate] = []
        func add(host: String, folder: String, target: PiFolder, usedBy: String?) {
            let key = "\(host)/\(folder)"
            guard seen.insert(key).inserted else { return }
            result.append(Candidate(hostID: host, hostName: names[host], folder: folder, target: target, usedBy: usedBy ?? owners[key]))
        }
        for item in sessions {
            guard let folder = item.state.folder else { continue }
            add(host: item.state.hostID, folder: folder, target: .besideSession(item.state.sessionID), usedBy: item.project?.name)
        }
        for binding in bindings where binding.projectID != project {
            add(host: binding.hostID, folder: binding.folder, target: .project(binding.projectID), usedBy: owners["\(binding.hostID)/\(binding.folder)"])
        }
        return result
    }

    /// 手机请 Mac 给项目绑文件夹的进度（读投送请求，不另存）：最近一次带文件夹的请求——还在路上，或已送到而绑定还没同步回来（请求在 Mac 上留一阵）是
    /// 正在绑，没成功是原因；解除绑定的请求不算。
    enum BindProgress: Equatable {
        case binding
        case failed(String)
    }

    static func bindProgress(of project: UUID, in requests: [DeliveryRequest]) -> BindProgress? {
        guard let latest = requests.filter({ $0.bind?.project == project && $0.bind?.folder != nil }).max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return latest.failure.map(BindProgress.failed) ?? .binding
    }
}
