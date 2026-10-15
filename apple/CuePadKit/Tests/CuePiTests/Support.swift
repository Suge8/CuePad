#if os(macOS)
import Foundation
import Synchronization
import Testing
import CueStore
import CueTestSupport
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
private let temporaryCounter = Atomic(0)

func makeTempDirectory() throws -> URL {
    let dir = temporaryRoot.appending(path: String(temporaryCounter.add(1, ordering: .relaxed).newValue), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    AgentTape.current?.register(temporaryDirectory: dir)
    return dir
}

/// 托管的 Pi 不随测试进程、桥或 `PiRuntime` 结束：用例收尾时给桥上还在的托管进程逐个发 SIGTERM。
/// 它们都连在本用例的临时 socket 目录里，是本用例启动的；只按这些 pid 发，不碰别的进程。
@MainActor func stopHostedProcesses(_ bridge: PiBridge) {
    for session in bridge.sessions where session.hosted { kill(session.pid, SIGTERM) }
}

func makeSocketDirectory() throws -> URL {
    try makeTempDirectory()
}

/// 一个从 socket 目录里消失的文件。
func fileGone(_ url: URL) -> Bool { !FileManager.default.fileExists(atPath: url.path) }

/// 已经退出的进程 pid（用于"残留 socket 的属主已死"）。
func deadPid() async throws -> Int32 {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    _ = try await p.runToExit()
    return p.processIdentifier
}

/// 测试读会话文件时你的消息里的图片存进的附件目录（要看存了什么的测试自己造一个资料库）。
let scratchFiles = try! Fixture().store.files

extension PiHistory {
    static func index(file: URL, from checkpoint: PiHistoryCheckpoint?, transcript: Bool = true) throws -> PiHistoryUpdate {
        try index(file: file, agent: .pi, from: checkpoint, transcript: transcript, files: scratchFiles)
    }
}

extension PiHistoryIndexer {
    /// 索引 `sessions` 这个会话目录（Pi 或 Codex 的，名字是 sessions：它的上层就是这家的配置目录）。
    init(sessions: URL, agent: AgentKind = .pi, start: @escaping @Sendable (URL) async -> PiHistoryStart? = { _ in nil }) {
        let home = sessions.deletingLastPathComponent()
        self.init(agent: agent, paths: AgentPaths(pi: PiPaths(agentDirectory: home), environment: ["CODEX_HOME": home.path]), files: scratchFiles, start: start)!
    }
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
