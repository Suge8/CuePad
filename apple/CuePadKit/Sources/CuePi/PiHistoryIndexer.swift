#if os(macOS)
import CueStore
import Foundation
import Synchronization

/// 会话的对话只从这里来：托管的会话没接入也开得出，所以没接入的 Agent 也要回填它托管过的那些。整棵目录只在回填时列一次，没经接入的会话（如 Pi 关了扩展）下次启动时进历史。
/// 歇下要等这一轮的回答从文件里读到才算（`PiSessionState.answered`），读晚一步 Cue 就晚一步被叫醒。
///
/// 不持有全部检查点：从哪接着读由调用方通过 `start` 提供（App 层从 Store 读），每个 `updated` 里带回新检查点由调用方持久化。
/// 索引器只对最近修改/最近被触碰的若干文件在内存里保留，这样调用方持久化滞后时增量也不会退化成重读。
public struct PiHistoryIndexer: Sendable {
    private let agent: AgentKind
    private let format: SessionFileFormat
    private let root: URL
    private let transcriptWindow: TimeInterval
    private let files: AttachmentFiles
    private let start: @Sendable (URL) async -> PiHistoryStart?

    private static let liveCacheLimit = 64

    /// 会话不在文件里的 Agent（OpenCode）为 nil。`files` 是你的消息里的图片存进的附件目录。
    public init?(
        agent: AgentKind, paths: AgentPaths, transcriptWindow: TimeInterval = .infinity, files: AttachmentFiles,
        start: @escaping @Sendable (URL) async -> PiHistoryStart?
    ) {
        guard let format = agent.facts.sessionFiles else { return nil }
        self.agent = agent
        self.format = format
        root = format.directory(paths)
        self.transcriptWindow = transcriptWindow
        self.files = files
        self.start = start
    }

    /// 会话目录可以还不存在（先装 CuePad、后装 Agent），见 `FileFollower`。
    /// `liveFiles` 是此刻在线会话的文件（各家的都行，不在这家会话目录里的不管），每次变了给一份。
    public func events(
        following liveFiles: some AsyncSequence<Set<URL>, Never> & Sendable, scope: PiHistoryScope
    ) -> AsyncStream<PiHistoryEvent> {
        AsyncStream { continuation in
            let task = Task(priority: .utility) { await run(continuation, following: liveFiles, scope: scope) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 同 `events`，但在调用方的任务里跑：取消后它返回时，跟随与读文件都已停下（不留脱离的任务攥着调用方给的东西）。
    @concurrent public func run(
        _ continuation: AsyncStream<PiHistoryEvent>.Continuation, following liveFiles: some AsyncSequence<Set<URL>, Never> & Sendable,
        scope: PiHistoryScope
    ) async {
        // 统一用真实路径，回填列出的与桥给的文件 URL 才一致（目录还不存在时解析其上层）
        let root = self.root.realPath
        let follower = FileFollower() // 先开始盯：回填期间的写入不会丢
        defer { follower.stop() }
        let sidecars = Mutex<[String: [URL]]>([:])
        let following = Task { [format] in
            var last: Set<URL>?
            for await files in liveFiles where files != last {
                last = files
                let mine = files.map(\.realPath).filter { Self.isSessionFile($0.path, under: root, format: format) }
                let named = format.sidecar.map { sidecar in Dictionary(grouping: mine) { sidecar.file($0).realPath.path } } ?? [:]
                sidecars.withLock { $0 = named }
                follower.follow(only: Set(mine.map(\.path)).union(named.keys))
            }
        }
        defer { following.cancel(); await following.value }
        var live = LiveCache(limit: Self.liveCacheLimit)
        var excluded: Set<URL> = []

        /// `size`：列目录时取的文件大小（文件变化通知来的没有）；与修改时间一起认出没动过的文件，不打开它（`isCurrent`）。
        func index(_ file: URL, modified: Date?, size: UInt64? = nil, remember: Bool) async {
            let base: PiHistoryStart?
            if let cached = live[file] { base = cached } else { base = await start(file) }
            let written = modified ?? Self.modified(file)
            let recent = written.map { $0 > Date.now.addingTimeInterval(-transcriptWindow) } ?? true
            let wanted = recent || base?.hasTranscript == true
            // 要对话而本机还没有：从头读一遍补齐，不靠接着读到的那一段碰巧完整
            let from = wanted && base?.hasTranscript != true ? nil : base?.checkpoint
            let checkpoint: PiHistoryCheckpoint
            var update: PiHistoryUpdate?
            let sidecarWritten = format.sidecar.flatMap { Self.modified($0.file(file)) }
            if let from, let size, let written, from.isCurrent(size: size, modified: written, sidecarModified: sidecarWritten) {
                checkpoint = from
            } else {
                // 文件已被删除/尚未落盘等：跳过，等下一次变化
                guard let read = try? PiHistory.index(file: file, agent: agent, from: from, transcript: wanted, modified: written, files: files)
                else { return }
                checkpoint = read.checkpoint
                update = read
            }
            if remember { live[file] = PiHistoryStart(checkpoint: checkpoint, hasTranscript: wanted || base?.hasTranscript == true) }
            if checkpoint.excluded {
                excluded.insert(file)
                return
            }
            guard format.isSession(checkpoint) else { return }
            // 没读到新内容也要写的：第一次索引，修改时间变了（记下它，下次启动才认得出没动过），另存的会话名变了
            guard let update, update.bytesRead > 0 || update.renamed
                || base?.checkpoint.map({ $0.modified != checkpoint.modified || $0.sidecarModified != checkpoint.sidecarModified }) ?? true
            else { return }
            continuation.yield(.updated(update))
        }

        // 回填时记住最近修改的那批文件（在线会话的就在其中）：之后盯到的写入落到缓存上，不会重读也不会重复发出
        let found = Self.sessionFiles(under: root, format: format).filter { scope.covers(sessionID: format.sessionID(of: $0.url)) }
        for (rank, file) in found.enumerated() {
            if Task.isCancelled { return }
            await index(file.url, modified: file.modified, size: file.size, remember: rank < Self.liveCacheLimit)
        }
        let sessionFiles = found.map(\.url).filter { !excluded.contains($0) }
        continuation.yield(.backfillFinished(sessionFiles: scope == .all ? sessionFiles : nil))

        for await path in follower.paths {
            if Task.isCancelled { return }
            for file in sidecars.withLock({ $0[path] }) ?? [URL(filePath: path)] { await index(file, modified: nil, remember: true) }
        }
    }

    private static func isSessionFile(_ path: String, under root: URL, format: SessionFileFormat) -> Bool {
        let url = URL(filePath: path)
        guard format.matches(url) else { return false }
        var parent = url
        for _ in 0..<format.depth { parent = parent.deletingLastPathComponent() }
        return parent.path == root.path
    }

    static func modified(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func sessionFiles(under root: URL, format: SessionFileFormat) -> [(url: URL, modified: Date, size: UInt64?)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(url: URL, modified: Date, size: UInt64?)] = []
        for case let url as URL in walker {
            guard walker.level == format.depth else { continue }
            walker.skipDescendants()  // 更深的子目录（如 subagents/）不进
            guard format.matches(url) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize.map(UInt64.init)))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    private struct LiveCache {
        let limit: Int
        private var values: [URL: PiHistoryStart] = [:]
        private var order: [URL] = []

        subscript(file: URL) -> PiHistoryStart? {
            get { values[file] }
            set {
                order.removeAll { $0 == file }
                guard let newValue else { values[file] = nil; return }
                values[file] = newValue
                order.append(file)
                if order.count > limit { values[order.removeFirst()] = nil }
            }
        }
    }
}
#endif
