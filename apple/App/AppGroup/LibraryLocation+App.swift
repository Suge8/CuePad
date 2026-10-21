import CueStore
import Foundation

/// 库位置的规则在 CueStore（`LibraryLocation`，唯一来源）；这里是 App 层在库目录里放的东西：
/// 分享扩展的待入库内容、给小组件与扩展的快照、偏好设置。
extension LibraryLocation {
    /// 分享扩展写入、主 App 入库的待处理内容（见 `CaptureQueue`）。
    var captureDirectory: URL { directory.appending(path: "Capture", directoryHint: .isDirectory) }
    /// 主 App 写给小组件与分享扩展读的快照（见 `Snapshots`）。
    var snapshotsDirectory: URL { directory.appending(path: "Snapshots", directoryHint: .isDirectory) }

    /// 偏好存储的套件名：隔离模式是库目录里的路径（文件是它加 `.plist`），iOS 是 App Group 标识（扩展才读得到）；
    /// macOS 用应用的标准偏好域（nil）。
    var preferencesSuite: String? {
        if isIsolated { return directory.appending(path: "preferences").path }
        #if os(iOS)
        return AppIdentity.appGroup
        #else
        return nil
        #endif
    }

    func makeDefaults() -> UserDefaults {
        guard let preferencesSuite else { return .standard }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: preferencesSuite) else {
            preconditionFailure("无法创建偏好存储 \(preferencesSuite)")
        }
        return defaults
    }
}
