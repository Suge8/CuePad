import Foundation

nonisolated enum LibraryLocationError: Error, LocalizedError {
    case relativePath(String)

    var errorDescription: String? {
        switch self {
        case .relativePath(let value): "CUEPAD_LIBRARY_DIR 必须是绝对路径，收到「\(value)」"
        }
    }
}

/// 本机资料库的位置。库文件与附件目录同级：附件在 `Attachments/`（CueStore 的约定）。
nonisolated struct LibraryLocation: Sendable {
    let directory: URL
    /// Electron 版数据库；只有 macOS 有，且可能不存在。
    let electronDatabase: URL?
    /// 隔离模式下偏好设置文件的位置（UserDefaults 的路径型套件名，实际文件是它加 `.plist`）；nil 用应用的标准偏好域。
    var preferencesSuite: String? = nil

    var databaseURL: URL { directory.appending(path: "cuepad.db") }
    var attachmentsDirectory: URL { directory.appending(path: "Attachments", directoryHint: .isDirectory) }

    /// 旧库导入完成的标记，与库同生共死：库被删掉后重新导入才是对的，标记留在别处则会漏导。
    var legacyImportMarker: URL { directory.appending(path: ".electron-import-completed") }

    /// 应用的偏好存储：隔离模式在库目录里，否则是 `UserDefaults.standard`。
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
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LibraryLocation {
        if let override = environment["CUEPAD_LIBRARY_DIR"], !override.isEmpty {
            guard override.hasPrefix("/") else { throw LibraryLocationError.relativePath(override) }
            let directory = URL(filePath: override, directoryHint: .isDirectory)
            return LibraryLocation(
                directory: directory, electronDatabase: nil,
                preferencesSuite: directory.appending(path: "preferences").path)
        }
        let support = URL.applicationSupportDirectory
        #if os(macOS)
        let electron: URL? = support.appending(path: "cuepad/cuepad.db")
        #else
        let electron: URL? = nil
        #endif
        return LibraryLocation(
            directory: support.appending(path: "CuePad/Library", directoryHint: .isDirectory),
            electronDatabase: electron)
    }

    /// 给没有别处处理错误的调用方（`AppServices()`）：环境变量非法时带原因终止。
    static var standard: LibraryLocation {
        do { return try resolve() } catch { preconditionFailure("\(error.localizedDescription)") }
    }
}
