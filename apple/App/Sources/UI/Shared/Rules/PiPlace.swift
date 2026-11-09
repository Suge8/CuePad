import CueStore

/// 手机上的会话记录带着 Mac 写入的文件夹名（旧版本写的没有，就不写）。
nonisolated enum PiPlace {
    /// `besides`：同一行里已经写着的会话名。会话名以所在开头（名字就是文件夹名，或"flow 3"在 flow 里，忽略大小写）时不再重复，副行只留状态。
    static func name(project: Project?, folder: String?, besides title: String? = nil) -> String? {
        guard let place = project?.shownName ?? folder else { return nil }
        return title?.lowercased().hasPrefix(place.lowercased()) == true ? nil : place
    }

    static func name(of state: PiSessionState, project: Project?) -> String? {
        name(project: project, folder: state.folder, besides: state.title)
    }

    static func menuTitle(of state: PiSessionState, project: Project?) -> String? {
        name(of: state, project: project).map { String(localized: "在 \($0)") }
    }
}
