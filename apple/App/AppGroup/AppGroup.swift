import Foundation

/// 主 App、分享扩展与小组件共用的容器（iOS）。资料库、待入库的分享内容与小组件快照都在里面。
nonisolated enum AppGroup {
    static let identifier = "group.com.sugeh.cuepad"

    /// 没有该 App Group 权限时为 nil。只在 iOS 使用：macOS 的 App Group 需要团队前缀，且访问会触发系统授权提示。
    static var containerURL: URL? {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #else
        nil
        #endif
    }
}
