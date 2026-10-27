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

/// 本进程所有临时目录的根：`/tmp/cpt-<本进程 pid>/N`（socket 路径有 104 字节上限，所以路径要短）。进程退出时停掉还在里面跑的进程
/// （`TestProcesses`）再整体删除；进程被中断（超时被杀、崩溃）来不及收尾的，或删掉目录后才又被拉起的（Codex 的常驻服务），
/// 下一次运行开始时按路径里的 pid 认出主人已不在，同样收掉（另起线程：不挡着第一个建临时目录的用例）。
private let temporaryRoot: URL = {
    let parent = URL(filePath: "/tmp", directoryHint: .isDirectory)
    let root = parent.appending(path: "\(temporaryPrefix)\(getpid())", directoryHint: .isDirectory)
    Thread.detachNewThread { removeTemporaryRoots(abandonedRoots(in: parent)) }
    try? FileManager.default.removeItem(at: root)  // 同一 pid 的上一次运行留下的
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    atexit { removeTemporaryRoots([URL(filePath: "/tmp/\(temporaryPrefix)\(getpid())")]) }
    return root
}()
private let temporaryPrefix = "cpt-"

/// 主人已不在的临时根：目录还在的，与目录删了、进程还指着它的。
private func abandonedRoots(in parent: URL) -> [URL] {
    let marker = "/tmp/\(temporaryPrefix)"
    let listed = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    let referenced = TestProcesses.referencedPaths(containing: marker).compactMap { path in
        path.range(of: marker).map { String(path[$0.lowerBound...].dropFirst("/tmp/".count).prefix { $0 != "/" }) }
    }
    return Set(listed + referenced).filter { name in
        guard name.hasPrefix(temporaryPrefix), let owner = pid_t(name.dropFirst(temporaryPrefix.count)) else { return false }
        return kill(owner, 0) == -1 && errno == ESRCH
    }.map { parent.appending(path: $0) }
}

private func removeTemporaryRoots(_ roots: [URL]) {
    TestProcesses.stop(under: roots)
    for root in roots { try? FileManager.default.removeItem(at: root) }
}
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

/// Pi 会话文件里的消息条目（文件顺序）：真实 Pi 写出的内容，作为投送是否到达模型的证据。
struct FileMessage {
    let id: String
    let parent: String?
    let role: String
    let text: String
    let images: Int
}

func fileMessages(in file: URL?) -> [FileMessage] {
    guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "message",
              let id = object["id"] as? String, let message = object["message"] as? [String: Any], let role = message["role"] as? String else { return nil }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = (message["content"] as? String) ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        return FileMessage(id: id, parent: object["parentId"] as? String, role: role, text: text, images: blocks.filter { $0["type"] as? String == "image" }.count)
    }
}

func fileTexts(_ role: String, in file: URL?) -> [String] { fileMessages(in: file).filter { $0.role == role }.map(\.text) }

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

    var details: [String?] {
        changes.compactMap { if case .stateChanged(let s, _) = $0 { s.detail } else { nil } }
    }

    var states: [PiWorkState] {
        changes.compactMap { if case .stateChanged(let s, _) = $0 { s.state } else { nil } }
    }

    /// 歇下了几次（连着的同一状态算一次）
    var settles: Int {
        zip(states, [nil] + states.map(Optional.some)).filter { $0 == .settled && $1 != .settled }.count
    }
}
#endif
