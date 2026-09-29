import CueStore
import Foundation

/// 首次启动从 Electron 旧库导入。
extension AppServices {
    /// 只导入一次：之后用户在新版里永久删除的内容不能被再次导回。失败不置完成标记，下次启动重试。
    func importLegacyIfNeeded() async {
        guard let source = location.electronDatabase,
              FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: location.legacyImportMarker.path)
        else { return }
        do {
            let report = try await store.importElectronLibrary(from: source)
            adoptLegacySettings(report.legacySettings)
            finishLegacyImport(report)
            try Data().write(to: location.legacyImportMarker)
        } catch {
            reportIssue(.legacyImportFailed("\(error)"))
        }
    }

    /// 旧库设置值是 JSON 文本（如 `"dark"`）。只作初始值，且快捷键必须是本版支持的。
    private func adoptLegacySettings(_ legacy: [String: String]) {
        func string(_ key: String) -> String? {
            legacy[key].flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        }
        settings.adoptLegacy(theme: string("theme").flatMap(AppSettings.Theme.init(rawValue:)), globalShortcut: shortcutIfSupported(string("globalShortcut")))
        #if os(macOS)
        applySavedShortcut()
        #endif
    }

    private func shortcutIfSupported(_ accelerator: String?) -> String? {
        #if os(macOS)
        accelerator.flatMap { Shortcut(accelerator: $0) == nil ? nil : $0 }
        #else
        nil
        #endif
    }
}
