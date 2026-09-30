import Foundation

nonisolated enum LibraryLocationError: Error, LocalizedError {
    case relativePath(String)
    case appGroupUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .relativePath(let value): "CUEPAD_LIBRARY_DIR 必须是绝对路径，收到「\(value)」"
        case .appGroupUnavailable(let id): "无法访问共享容器 \(id)：App 没有该 App Group 的权限（真机需要开发者签名）"
        }
    }
}

/// 本机资料库的位置。库文件与附件目录同级：附件在 `Attachments/`（CueStore 的约定）。
nonisolated struct LibraryLocation: Sendable {
    let directory: URL
    /// Electron 版数据库；只有 macOS 有，且可能不存在。
    let electronDatabase: URL?
    /// 偏好存储的套件名：隔离模式是库目录里的路径（文件是它加 `.plist`），iOS 是 App Group 标识；nil 用应用的标准偏好域。
    var preferencesSuite: String? = nil

    var databaseURL: URL { directory.appending(path: "cuepad.db") }
    /// 分享扩展写入、主 App 入库的待处理内容（见 `CaptureInbox`）。
    var captureDirectory: URL { directory.appending(path: "Capture", directoryHint: .isDirectory) }
    /// 主 App 写给小组件与分享扩展读的快照（见 `Snapshots`）。
    var snapshotsDirectory: URL { directory.appending(path: "Snapshots", directoryHint: .isDirectory) }
    var attachmentsDirectory: URL { directory.appending(path: "Attachments", directoryHint: .isDirectory) }

    /// 旧库导入完成的标记，与库同生共死：库被删掉后重新导入才是对的，标记留在别处则会漏导。
    var legacyImportMarker: URL { directory.appending(path: ".electron-import-completed") }

    /// 应用的偏好存储：隔离模式在库目录里，iOS 用 App Group 的套件，macOS 是 `UserDefaults.standard`。
    func makeDefaults() -> UserDefaults {
        guard let preferencesSuite else { return .standard }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: preferencesSuite) else {
            preconditionFailure("无法创建隔离偏好存储 \(preferencesSuite)")
        }
        return defaults
    }

    /// 环境变量 `CUEPAD_LIBRARY_DIR` 指向隔离目录（开发与视觉验收用）：资料库与偏好设置都放进去，不导入旧库，
    /// 与真实数据和其他并行的实例互不影响。必须是绝对路径。
    /// iOS 的真实位置在 App Group 共享容器里（偏好也用该组的套件，扩展才读得到）。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appGroupContainer: URL? = AppGroup.containerURL
    ) throws -> LibraryLocation {
        if let override = environment["CUEPAD_LIBRARY_DIR"], !override.isEmpty {
            guard override.hasPrefix("/") else { throw LibraryLocationError.relativePath(override) }
            let directory = URL(filePath: override, directoryHint: .isDirectory)
            return LibraryLocation(
                directory: directory, electronDatabase: nil,
                preferencesSuite: directory.appending(path: "preferences").path)
        }
        #if os(iOS)
        guard let container = appGroupContainer else { throw LibraryLocationError.appGroupUnavailable(AppGroup.identifier) }
        return LibraryLocation(
            directory: container.appending(path: "Library", directoryHint: .isDirectory), electronDatabase: nil,
            preferencesSuite: AppGroup.identifier)
        #else
        let support = URL.applicationSupportDirectory
        return LibraryLocation(
            directory: support.appending(path: "CuePad/Library", directoryHint: .isDirectory),
            electronDatabase: support.appending(path: "cuepad/cuepad.db"))
        #endif
    }

    /// 给没有别处处理错误的调用方（`AppServices()`）：环境变量非法时带原因终止。
    static var standard: LibraryLocation {
        do { return try resolve() } catch { preconditionFailure("\(error.localizedDescription)") }
    }
}
