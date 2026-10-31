import CueStore
import Foundation

/// 项目与文件夹的规则（iOS 与 Mac 共用）。绑定是 Mac 本机的事（`CueStore.setDirectory`，路径因设备而异）；
/// 手机能看到的只有各 Mac 同步来的目录绑定（`DirectoryBinding`：文件夹名，读出时带上那台 Mac 报的名字），要绑时经投送请求（`PiBind`）让那台 Mac 解析成完整路径。
nonisolated enum ProjectFolders {
    /// 新会话可以开在哪：每个项目一项，按项目的顺序（`ProjectCatalog.projects`）；同一项目绑在几台 Mac 上时每台一项
    /// （手机选发给哪台 Mac，`detail` 写 Mac 名）。没绑文件夹的也直接开：交给 `host`（开工时那台 Mac 建工作区并绑定）。
    struct LaunchPlace: Identifiable, Equatable, Sendable {
        let id: String
        let project: Project
        /// 由哪台 Mac 开：绑着文件夹的那台；没绑的是建工作区的那台（Mac 上是本机，手机上是 `CueStore.workMac`）。手机上一台 Mac 都没有为 nil。
        let host: String?
        let detail: String?
    }

    /// `host` 是 Mac 上本机的标识：新会话只在本机开，只认本机的绑定；手机传 nil，看全部，没绑的交给 `workMac`。
    static func launchPlaces(projects: [Project], bindings: [DirectoryBinding], host: String?, workMac: String?) -> [LaunchPlace] {
        projects.flatMap { project -> [LaunchPlace] in
            let own = bindings.filter { $0.projectID == project.id && (host == nil || $0.hostID == host) }
            guard !own.isEmpty else { return [LaunchPlace(id: project.id.uuidString, project: project, host: host ?? workMac, detail: nil)] }
            return own.map { binding in
                LaunchPlace(id: binding.id.uuidString, project: project, host: binding.hostID, detail: own.count > 1 ? binding.macName : nil)
            }
        }
    }

    /// 还没绑文件夹时接在工作区后面的那一段（"~/CuePad/Flow · 开工时建好"，Mac 与手机同一句）。
    static var pending: String { String(localized: "开工时建好") }

    /// 手机上项目的文件夹在哪（`ProjectPlace`）："Mac Studio 上的 cuepad"，绑在几台 Mac 上各写一段。只写文件夹名：
    /// 同步来的绑定只有末段（完整路径不出那台 Mac）。哪台都没绑时写 `workMac` 开工时会建的那个（`Workspaces.folderName`）；
    /// 一台 Mac 都没有时说开工要一台 Mac。
    static func place(of project: Project, bindings: [DirectoryBinding], workMac: MacAgents?) -> Dotted {
        let own = bindings.filter { $0.projectID == project.id }
        guard own.isEmpty else { return Dotted(own.map { String(localized: "\($0.macName) 上的 \($0.folder)") }) }
        guard let workMac else { return Dotted(String(localized: "开工要一台装了 CuePad 的 Mac")) }
        return Dotted(String(localized: "\(workMac.shownName) 上的 \(Workspaces.folderName(for: project.name))"), pending)
    }

    /// 项目操作菜单里的绑定项（`ProjectActions`）："换文件夹…"之外，绑着的每处一项解除（解除后下次开工回到工作区）；
    /// Mac 上只管本机的绑定，手机上管全部，绑在几台 Mac 上时解除按 Mac 分开。
    struct Menu: Equatable {
        struct Unbind: Equatable {
            let title: Dotted
            let binding: DirectoryBinding
        }

        let unbinds: [Unbind]
    }

    static func menu(for project: UUID, bindings: [DirectoryBinding], host: String?) -> Menu {
        let own = bindings.filter { $0.projectID == project && (host == nil || $0.hostID == host) }
        return Menu(unbinds: own.map { Menu.Unbind(title: Dotted(String(localized: "解除绑定"), own.count > 1 ? $0.macName : nil), binding: $0) })
    }

    /// 手机上给项目选文件夹的一个候选：Mac 上已知的一个文件夹（只有名字）与"让那台 Mac 从哪里取"。
    struct Candidate: Identifiable, Equatable, Sendable {
        var id: String { "\(hostID)/\(folder)" }
        let hostID: String
        /// 那台 Mac 给人看的名字（`MacAgents.shownName`）。
        let macName: String
        let folder: String
        let target: PiFolder
        /// 已经是哪个项目在用（会话归的项目，或绑着它的项目）。
        let usedBy: String?
        /// 那个文件夹里跑过的 Agent 会话数（别的项目绑着、没有会话的是 0）。
        let sessions: Int
    }

    /// 按设备分组；显示名可相同，设备标识才是稳定的组标识。
    struct CandidateGroup: Identifiable {
        let id: String
        let name: String?
        let items: [Candidate]
    }

    static func candidateGroups(_ candidates: [Candidate]) -> [CandidateGroup] {
        let byHost = Dictionary(grouping: candidates, by: \.hostID)
        return byHost.map { host, items in
            CandidateGroup(id: host, name: byHost.count > 1 ? items.first?.macName : nil, items: items)
        }.sorted { $0.id < $1.id }
    }

    /// 候选来自同步来的现成数据：各 Mac 上跑过 Agent 的文件夹（`CueStore.sessionFolders`，最近的在前），其次是别的项目绑着、但没有会话跑过的文件夹；
    /// 同一台 Mac 上同名的只列一个（手机分不出同名的两个文件夹）；`excluding` 项目在那台 Mac 上已绑着的不再列。
    static func candidates(folders: [SessionFolder], bindings: [DirectoryBinding], projects: [Project], excluding project: UUID?) -> [Candidate] {
        let own = Set(bindings.filter { $0.projectID == project }.map { "\($0.hostID)/\($0.folder)" })
        let owners = Dictionary(
            bindings.filter { $0.projectID != project }.compactMap { binding in
                projects.first { $0.id == binding.projectID }.map { ("\(binding.hostID)/\(binding.folder)", $0.shownName) }
            }, uniquingKeysWith: { first, _ in first })
        var seen = own
        var result: [Candidate] = []
        func add(host: String, macName: String, folder: String, target: PiFolder, usedBy: String?, sessions: Int) {
            let key = "\(host)/\(folder)"
            guard seen.insert(key).inserted else { return }
            result.append(Candidate(hostID: host, macName: macName, folder: folder, target: target, usedBy: usedBy ?? owners[key], sessions: sessions))
        }
        for item in folders {
            add(
                host: item.hostID, macName: item.macName, folder: item.folder, target: .besideSession(item.sessionID),
                usedBy: item.projectID.flatMap { id in projects.first { $0.id == id }?.shownName }, sessions: item.count)
        }
        for binding in bindings where binding.projectID != project {
            add(host: binding.hostID, macName: binding.macName, folder: binding.folder, target: .project(binding.projectID), usedBy: nil, sessions: 0)
        }
        return result
    }
}
