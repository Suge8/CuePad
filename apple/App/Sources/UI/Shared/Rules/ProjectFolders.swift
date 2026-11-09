import CueStore
import Foundation

/// 项目与文件夹的规则（iOS 与 Mac 共用）。绑定是 Mac 本机的事（`CueStore.setDirectory`，路径因设备而异）；
/// 手机能看到的只有各 Mac 同步来的目录绑定（`DirectoryBinding`），要绑时经投送请求（`PiBind`）让那台 Mac 解析成完整路径。
nonisolated enum ProjectFolders {
    struct LaunchPlace: Identifiable, Equatable, Sendable {
        let id: String
        let project: Project
        /// 没绑的是建工作区的那台（Mac 上是本机，手机上是 `CueStore.workMac`）。手机上一台 Mac 都没有为 nil。
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

    static var pending: String { String(localized: "开工时建好") }

    /// 只写文件夹名：同步来的绑定只有末段（完整路径不出那台 Mac）。
    static func place(of project: Project, bindings: [DirectoryBinding], workMac: MacAgents?) -> Dotted {
        let own = bindings.filter { $0.projectID == project.id }
        guard own.isEmpty else { return Dotted(own.map { String(localized: "\($0.macName) 上的 \($0.folder)") }) }
        guard let workMac else { return Dotted(String(localized: "开工要一台装了 CuePad 的 Mac")) }
        return Dotted(String(localized: "\(workMac.shownName) 上的 \(Workspaces.folderName(for: project.name))"), pending)
    }

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

    struct Candidate: Identifiable, Equatable, Sendable {
        var id: String { "\(hostID)/\(folder)" }
        let hostID: String
        let macName: String
        let folder: String
        let target: PiFolder
        let usedBy: String?
        let sessions: Int
    }

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
