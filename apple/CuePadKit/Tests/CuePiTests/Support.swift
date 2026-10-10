#if os(macOS)
import Foundation
import Testing
import CueStore
@testable import CuePi

/// CueStore 里也有同名的会话索引类型；这里说的都是桥上的会话。
typealias PiSession = CuePi.PiSession

// MARK: - 临时目录 / 条件等待

/// 本进程所有临时目录的根（进程退出时整体删除）。socket 路径有 104 字节上限，所以路径要短：`/tmp/cpt-XXXXXX/N`。
private let temporaryRoot: URL = {
    let root = URL(filePath: "/tmp/cpt-\(String(UUID().uuidString.prefix(6)))", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    atexit { try? FileManager.default.removeItem(atPath: temporaryRootPath) }
    temporaryRootPath = root.path
    return root
}()
nonisolated(unsafe) private var temporaryRootPath = ""
private let temporaryCounter = LockedCounter()

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

func makeTempDirectory() throws -> URL {
    let dir = temporaryRoot.appending(path: String(temporaryCounter.next()), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir
}

func makeSocketDirectory() throws -> URL {
    try makeTempDirectory()
}

struct TimedOut: Error, CustomStringConvertible {
    var description: String
}

/// 条件等待：状态由 FSEvents/socket 异步推进，没有更细的完成信号可订阅时用它，禁止固定 sleep。
func eventually(
    _ what: String, timeout: Duration = .seconds(10),
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(15))
    }
    throw TimedOut(description: "timed out waiting for: \(what)")
}

/// 一个从 socket 目录里消失的文件。
func fileGone(_ url: URL) -> Bool { !FileManager.default.fileExists(atPath: url.path) }

/// 已经退出的进程 pid（用于"残留 socket 的属主已死"）。
func deadPid() throws -> Int32 {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    return p.processIdentifier
}

/// 会话文件此刻的摘要（对话的投影，见 `PiHistory`）；文件还没落盘时为 nil。
func recap(of session: PiSession?) -> PiRecap? {
    session?.sessionFile.flatMap { try? PiHistory.index(file: $0, from: nil).checkpoint.recap }
}

/// 订阅 `changes()` 并记录，供测试断言事件顺序。
@MainActor
final class ChangeLog {
    private(set) var changes: [PiSessionChange] = []
    private var task: Task<Void, Never>?

    init(_ bridge: PiBridge) {
        let stream = bridge.changes()
        task = Task { [weak self] in
            for await change in stream { self?.changes.append(change) }
        }
    }

    deinit { task?.cancel() }

    var ended: [(PiSession, PiSessionEndReason)] {
        changes.compactMap { if case .ended(let s, let r) = $0 { (s, r) } else { nil } }
    }

    /// 每次状态变化时的一句话说明（`PiSession.detail`）
    var details: [String?] {
        changes.compactMap { if case .stateChanged(let s, _) = $0 { s.detail } else { nil } }
    }

    var states: [PiWorkState] {
        changes.compactMap { if case .stateChanged(let s, _) = $0 { s.state } else { nil } }
    }
}
#endif
