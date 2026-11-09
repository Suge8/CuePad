import CueStore
import CueSync
import Foundation
import os

/// Mac 上把各台设备经 iCloud 送来的诊断（`DeviceDiagnostic`）落成文件：`<directory>/<设备名>/<文件名>`，云上删了的这里也删，
/// 与各台的存档一样只留最近几份。`directory` 是 `LibraryLocation.deviceLogs`（正式版在 ~/Library/Logs/CuePad，不在资料库里：
/// agent 读它不碰真实资料库；隔离库在自己目录里），`xc.sh diag` 读它、符号化。
/// 进度（拉到哪的令牌、设备 ID 对应哪个目录）记在 `directory/.inbox.json`；令牌失效或文件丢了就从头读一遍、照云上的全部重写。
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

    /// 拉一遍、写下：返回写了几份、删了几份。没拉成的抛出（等账号、被限流时同 `CloudSync.diagnosticChanges`）。
    @discardableResult
    func check() async throws -> (written: Int, removed: Int) {
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
        let changes = try await sync.diagnosticChanges(since: state.token)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var removed = 0
        if changes.complete {
            // 从头读的：本地有、云上没有的都删
            let keep = Set(changes.saved.map { folder(for: $0, in: &state).appending(path: $0.file).path })
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
            removed += 1
        }
        for diagnostic in changes.saved {
            let folder = folder(for: diagnostic, in: &state)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try diagnostic.content.write(to: folder.appending(path: diagnostic.file), options: .atomic)
        }
        state.token = changes.token.isEmpty ? nil : changes.token
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        if !changes.saved.isEmpty || removed > 0 {
            Self.log.notice("收下各设备的诊断：写 \(changes.saved.count) 份、删 \(removed) 份，在 \(self.directory.path, privacy: .public)")
        }
        return (changes.saved.count, removed)
    }

    /// 按设备名分目录；两台同名的，后来的加上设备 ID 的头几位。
    private func folder(for diagnostic: DeviceDiagnostic, in state: inout State) -> URL {
        if let name = state.folders[diagnostic.device] { return directory.appending(path: name, directoryHint: .isDirectory) }
        let base = diagnostic.deviceName.replacing("/", with: "-").replacing(":", with: "-")
        let taken = Set(state.folders.values)
        let name = taken.contains(base) ? "\(base) \(diagnostic.device.prefix(8))" : base
        state.folders[diagnostic.device] = name
        return directory.appending(path: name, directoryHint: .isDirectory)
    }

    /// 跟着 App 一直跑：先看一次，之后每 `every` 看一次。看不成的（没登录、被限流、断网）记一条，到点再看。
    func watch(every: Duration) async {
        while !Task.isCancelled {
            do { try await check() } catch is CancellationError { return } catch {
                Self.log.notice("各设备的诊断这次没拉成，\(every) 后再看：\(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(for: every)
        }
    }
}
