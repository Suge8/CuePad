import CryptoKit
import CueStore
import CueSync
import Foundation
import OSLog

/// 日志先原子落盘，再异步上传最新一份；网络与记录失败不参与活动决策，不额外申请后台运行时间。
/// 按资料所属账号分文件，未认账号的记录只留本机；账号变化后不会把旧账号取证传给新账号。
actor ActivityDiagnosticRecorder {
    private let directory: URL
    private let device: String
    private var pending: (report: ActivityDiagnosticReport, account: String)?
    private var sending: Task<Void, Never>?
    private static let log = Logger(subsystem: AppIdentity.id, category: "activity-diagnostics")

    @MainActor private static var recorders: [URL: ActivityDiagnosticRecorder] = [:]

    @MainActor static func shared(directory: URL, device: String) -> ActivityDiagnosticRecorder {
        let key = directory.standardizedFileURL
        if let recorder = recorders[key] { return recorder }
        let recorder = ActivityDiagnosticRecorder(directory: key, device: device)
        recorders[key] = recorder
        return recorder
    }

    private init(directory: URL, device: String) {
        self.directory = directory.appending(path: "ActivityDiagnostics", directoryHint: .isDirectory)
        self.device = device
    }

    func record(_ event: ActivityDiagnosticReport.Event, account: Data?) {
        do {
            let account = account.map { String(decoding: $0, as: UTF8.self) }
            let tag = account.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } ?? "unconfirmed"
            let file = directory.appending(path: "\(tag).json")
            var report = if FileManager.default.fileExists(atPath: file.path) {
                try JSONDecoder().decode(ActivityDiagnosticReport.self, from: Data(contentsOf: file))
            } else {
                ActivityDiagnosticReport(device: device)
            }
            let cutoff = Date.now.addingTimeInterval(-ActivityDiagnosticReport.retention)
            report.events.removeAll { $0.at < cutoff }
            report.append(event)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: file, options: .atomic)
            for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                if try old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate.map({ $0 < cutoff }) == true {
                    try FileManager.default.removeItem(at: old)
                }
            }
            guard let account else { return }
            pending = (report, account)
            guard sending == nil else { return }
            sending = Task { await drain() }
        } catch {
            Self.log.error("活动取证未能落盘：\((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    private func drain() async {
        defer { sending = nil }
        while let next = pending {
            pending = nil
            do {
                try await ActivityDiagnosticCloud().save(next.report, account: next.account)
                Self.log.info("活动取证已上传，\(next.report.events.count) 条")
            } catch {
                Self.log.error("活动取证未上传，本机记录保留：\((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                return
            }
        }
    }
}
