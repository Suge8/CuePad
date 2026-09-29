import Foundation

/// 本机资料库的位置。库文件与附件目录同级：附件在 `Attachments/`（CueStore 的约定）。
nonisolated struct LibraryLocation: Sendable {
    let directory: URL
    /// Electron 版数据库；只有 macOS 有，且可能不存在。
    let electronDatabase: URL?

    var databaseURL: URL { directory.appending(path: "cuepad.db") }
    var attachmentsDirectory: URL { directory.appending(path: "Attachments", directoryHint: .isDirectory) }
    /// 旧库导入完成的标记，与库同生共死：库被删掉后重新导入才是对的，标记留在别处则会漏导。
    var legacyImportMarker: URL { directory.appending(path: ".electron-import-completed") }

    /// 环境变量 `CUEPAD_LIBRARY_DIR` 指向隔离的资料库目录（开发与视觉验收用），此时不导入旧库。
    static var standard: LibraryLocation {
        if let override = ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"], !override.isEmpty {
            return LibraryLocation(directory: URL(filePath: override, directoryHint: .isDirectory), electronDatabase: nil)
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
}
