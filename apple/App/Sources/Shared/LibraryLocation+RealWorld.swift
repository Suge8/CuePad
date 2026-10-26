import CueStore
#if os(macOS)
import AppKit
#endif

extension LibraryLocation {
    /// 这个进程碰不碰这台设备上的真实世界（唯一判断）：各家 Agent 的配置目录（接入时写的技能、钩子与扩展）、`~/.local/bin` 里的命令行链接、
    /// 缺省的连接目录（会话与钩子的 socket）、工作区根目录 `~/CuePad`、系统通知与角标、MetricKit 诊断、实时活动、主机标识。
    /// 这些按 bundle id 或固定位置记，本机构建与正式版共用；库放哪是另一件事（`isIsolated`）。
    /// - 环境变量指定的隔离库（xc.sh、测试）：不碰。
    /// - 正式版：碰。
    /// - 本机构建的开发库：这台 Mac 装着正式版时不碰（维护者的 Mac：那些配置是正式版写的、指向正式版，开发构建一接入就改成指向自己，
    ///   还会抢走正式版的 socket 与通知）；没装时碰（克隆仓库自己编的人，这就是他唯一的 CuePad）。
    var touchesRealWorld: Bool {
        switch origin {
        case .release: true
        case .development: !Self.releaseInstalled
        case .override:
            switch DebugHooks.actsAs {
            case nil: false
            case .development?: !Self.releaseInstalled
            case .stranger?: true
            }
        }
    }

    /// 这台 Mac 上装着正式版：LaunchServices 按 bundle id 登记的副本里有正式版（`AppIdentity.isRelease`）。本机构建与正式版同一个 bundle id，
    /// 按包里的正式版标记分。装进"应用程序"、~/Applications 或打开过一次的都已登记；拷到别处、从没打开过的找不到，算没装。
    private static let releaseInstalled: Bool = {
        #if os(macOS)
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).contains { AppIdentity.isRelease(at: $0) }
        #else
        false
        #endif
    }()
}
