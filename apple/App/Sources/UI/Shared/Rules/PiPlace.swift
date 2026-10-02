import CueStore

/// Pi 会话"在哪"的一个词，是会话行副行的开头（Mac 侧栏、菜单栏与 iOS 活动页共用这一条规则）：
/// 工作目录绑定了项目时是项目名，否则是文件夹名。iOS 只拿得到 Mac 同步来的项目，没有文件夹名时就不写。
enum PiPlace {
    static func name(project: Project?, folder: String?) -> String? {
        project?.name ?? folder
    }
}
