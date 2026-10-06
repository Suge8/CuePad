import CueStore

/// Pi 会话"在哪"的一个词，是会话行副行的开头（Mac 侧栏、菜单栏与 iOS 的 Agent 页共用这一条规则）：
/// 工作目录绑定了项目时是项目名，否则是文件夹名。手机上的会话记录带着 Mac 写入的文件夹名（旧版本写的没有，就不写）。
enum PiPlace {
    /// `besides`：同一行里已经写着的会话名。所在与它相同（会话名就是文件夹名）时不再重复，副行只留状态。
    static func name(project: Project?, folder: String?, besides title: String? = nil) -> String? {
        let place = project?.name ?? folder
        return place == title ? nil : place
    }

    /// 同步来的会话记录（手机）。
    static func name(of state: PiSessionState, project: Project?) -> String? {
        name(project: project, folder: state.folder, besides: state.title)
    }
}
