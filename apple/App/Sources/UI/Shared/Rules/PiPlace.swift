import CueStore

/// Pi 会话"在哪"的一个词，是会话行副行的开头（Mac 侧栏、菜单栏与 iOS 的 Agent 页共用这一条规则）：
/// 工作目录绑定了项目时是项目名，否则是文件夹名。手机上的会话记录带着 Mac 写入的文件夹名（旧版本写的没有，就不写）。
nonisolated enum PiPlace {
    /// `besides`：同一行里已经写着的会话名。会话名以所在开头（名字就是文件夹名，或"flow 3"在 flow 里，忽略大小写）时不再重复，副行只留状态。
    static func name(project: Project?, folder: String?, besides title: String? = nil) -> String? {
        guard let place = project?.name ?? folder else { return nil }
        return title?.lowercased().hasPrefix(place.lowercased()) == true ? nil : place
    }

    /// 同步来的会话记录（手机）。
    static func name(of state: PiSessionState, project: Project?) -> String? {
        name(project: project, folder: state.folder, besides: state.title)
    }

    /// 会话页"⋯"菜单最上面的一行："在 CuePad · 后台"（所在与 Mac 在后台开的，会话页顶栏不写它们）；都没有时是 nil。
    static func menuTitle(of state: PiSessionState, project: Project?) -> Dotted? {
        Dotted(name(of: state, project: project).map { "在 \($0)" }, state.hosted && state.state != .known(.ended) ? "后台" : nil).nonEmpty
    }
}
