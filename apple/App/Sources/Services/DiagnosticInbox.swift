import CueStore
import CueSync
import Foundation
import os

actor DiagnosticInbox {
    /// Mac 不收推送、诊断区也没有门铃：隔这么久看一次（另在同步认好账号后先看一次）。一次一个请求，比在等时的同步拉取（2 秒一次）少两个数量级；
    /// 代价是手机上点了"把最近日志发到 Mac"，最多这么久才落到 Mac 上。
    static let interval = Duration.seconds(300)

    private struct State: Codable {
        var token: Data?
        var folders: [String: String] = [:]
    }

    nonisolated let directory: URL
    private let sync: CloudSync
    private static let log = Logger(subsystem: AppIdentity.id, category: "diagnostics")

    init(directory: URL, sync: CloudSync) {
        self.directory = directory
        self.sync = sync
    }

    private var stateFile: URL { directory.appending(path: ".inbox.json") }

    @discardableResult
    func check() async throws -> (written: Int, removed: Int) {
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
        let changes = try await sync.diagnosticChanges(since: state.token)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var removed = 0
        if changes.complete {
            let keep = Set(changes.saved.flatMap { saved in
                let file = folder(for: saved, in: &state).appending(path: saved.file)
                return [file.path, Self.summary(of: file).path]
            })
            for (device, name) in state.folders {
                let folder = directory.appending(path: name, directoryHint: .isDirectory)
                for file in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(folder.appending(path: file).path) {
                    try files.removeItem(at: folder.appending(path: file))
                    removed += 1
                }
                if !changes.saved.contains(where: { $0.device == device }) { state.folders[device] = nil }
            }
        }
        for gone in changes.deleted {
            guard let name = state.folders[gone.device] else { continue }
            let file = directory.appending(path: name).appending(path: gone.file)
            guard files.fileExists(atPath: file.path) else { continue }
            try files.removeItem(at: file)
            try? files.removeItem(at: Self.summary(of: file))
            removed += 1
        }
        for diagnostic in changes.saved {
            let folder = folder(for: diagnostic, in: &state)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: diagnostic.file)
            try diagnostic.content.write(to: file, options: .atomic)
            let reports = CrashReport.reports(file: diagnostic.file, json: diagnostic.content)
            if !reports.isEmpty { try JSONEncoder.diagnostics.encode(reports.map(CrashReport.Summary.init)).write(to: Self.summary(of: file), options: .atomic) }
        }
        state.token = changes.token.isEmpty ? nil : changes.token
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        if !changes.saved.isEmpty || removed > 0 {
            Self.log.notice("收下各设备的诊断：写 \(changes.saved.count) 份、删 \(removed) 份，在 \(self.directory.path, privacy: .public)")
        }
        return (changes.saved.count, removed)
    }

    private static func summary(of file: URL) -> URL { file.appendingPathExtension("summary.json") }

    private func folder(for diagnostic: DeviceDiagnostic, in state: inout State) -> URL {
        if let name = state.folders[diagnostic.device] { return directory.appending(path: name, directoryHint: .isDirectory) }
        let base = diagnostic.deviceName.replacing("/", with: "-").replacing(":", with: "-")
        let taken = Set(state.folders.values)
        let name = taken.contains(base) ? "\(base) \(diagnostic.device.prefix(8))" : base
        state.folders[diagnostic.device] = name
        return directory.appending(path: name, directoryHint: .isDirectory)
    }

    func watch(every: Duration) async {
        while !Task.isCancelled {
            do { try await check() } catch is CancellationError { return } catch {
                Self.log.notice("各设备的诊断这次没拉成，\(every) 后再看：\(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: every)
        }
    }
}
