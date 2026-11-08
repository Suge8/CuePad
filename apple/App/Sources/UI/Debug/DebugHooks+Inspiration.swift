import SwiftUI

extension DebugHooks {
    #if os(iOS)
    static func inspirationActivities() -> [UIActivity]? {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "CuePadInspirationAudit") else { return nil }
        return [InspirationAuditActivity(destination: URL(filePath: path))]
        #else
        return nil
        #endif
    }
    #endif

    /// `-CuePadInspirationAudit <目录>`：每个资源各写自己的创建/删除事件，验收系统消费期间的所有权与结束后的清理。
    nonisolated static func inspirationFileEvent(_ directory: URL, created: Bool) {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "CuePadInspirationAudit") else { return }
        let event = created ? "created" : "removed"
        let record: [String: Any] = ["event": event, "path": directory.path, "exists": FileManager.default.fileExists(atPath: directory.path)]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            try data.write(to: URL(filePath: path).appending(path: directory.lastPathComponent + "-" + event + ".json"))
        } catch { assertionFailure("灵感文件验收事件写入失败：\(error)") }
        #endif
    }
}
