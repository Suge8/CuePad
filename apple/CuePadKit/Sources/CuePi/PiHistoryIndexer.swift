#if os(macOS)
import CueStore
import Foundation

/// 后台索引一个 Agent 的会话目录（Pi、Claude Code、Codex 的会话文件，怎么认、怎么读见 `SessionFileFormat`）：先按修改时间倒序回填
/// （最近的会话最先可用），发出 `backfillFinished` 后用 FSEvents 跟随文件变化，只读新增字节。一直开着会话文件写的 Agent（Codex 的常驻服务），
/// FSEvents 只在关闭时报它的变化：它最近写过的文件另盯追加（`FSEventsWatcher.follow`，见 `Followed`）。
///
/// 不持有全部检查点：从哪接着读由调用方通过 `start` 提供（App 层从 Store 读），每个 `updated` 里带回新检查点由调用方持久化。
/// 索引器只对最近修改/最近被触碰的若干文件在内存里保留，这样调用方持久化滞后时增量也不会退化成重读。
///
/// 要不要对话：首次读（没有检查点）时只为 `transcriptWindow` 内修改过的文件（按修改时间，不读内容）解析对话；本机已存着对话的也要
/// （从头读时整份重写，规则升级后已存的跟着变）。要对话而本机还没有的（刚进入范围），从头读一遍补齐全部消息。
public struct PiHistoryIndexer: Sendable {
    private let agent: AgentKind
    private let format: SessionFileFormat
    private let root: URL
    private let transcriptWindow: TimeInterval
    private let files: AttachmentFiles
    private let start: @Sendable (URL) async -> PiHistoryStart?

    private static let liveCacheLimit = 64
    /// 同时另盯追加的文件数：每个占一个文件描述符，GUI 应用默认只有 256 个
    private static let followLimit = 64

    /// 会话不在文件里的 Agent（OpenCode）为 nil。`files` 是你的消息里的图片存进的附件目录。
    public init?(
        agent: AgentKind, paths: AgentPaths, transcriptWindow: TimeInterval = .infinity, files: AttachmentFiles,
        start: @escaping @Sendable (URL) async -> PiHistoryStart?
    ) {
        guard let format = SessionFileFormat.of(agent), let root = paths.sessionsDirectory(of: agent) else { return nil }
        self.agent = agent
        self.format = format
        self.root = root
        self.transcriptWindow = transcriptWindow
        self.files = files
        self.start = start
    }

    /// 结束（取消订阅）时停止后台任务。会话目录可以还不存在（先装 CuePad、后装 Agent）或被删再建，见 `FSEventsWatcher`。
    public func events() -> AsyncStream<PiHistoryEvent> {
        AsyncStream { continuation in
            let task = Task(priority: .utility) { await run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent private func run(_ continuation: AsyncStream<PiHistoryEvent>.Continuation) async {
        // FSEvents 报告真实路径；统一用真实路径，回填与增量的文件 URL 才一致（目录还不存在时解析其上层）
        let root = self.root.realPath
        let watcher = FSEventsWatcher(root: root) // 先开始监听：回填期间的变化不会丢
        defer { watcher.stop() }
        var live = LiveCache(limit: Self.liveCacheLimit)
        var excluded: Set<URL> = []
        var followed = Followed(limit: Self.followLimit)

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
            if let from, let size, let written, from.isCurrent(size: size, modified: written) {
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
            if format.keepsFilesOpen, let written {
                let change = followed.note(file.path, writtenAt: written)
                if let dropped = change.dropped { watcher.unfollow(dropped) }
                if change.follows { watcher.follow(file.path) }
            }
            guard format.isSession(checkpoint) else { return }
            // 没读到新内容也要写的：第一次索引，与修改时间变了（记下它，下次启动才认得出没动过）
            guard let update, update.bytesRead > 0 || base?.checkpoint.map({ $0.modified != checkpoint.modified }) ?? true else { return }
            continuation.yield(.updated(update))
        }

        // 回填时记住最近修改的那批文件（正在被 Agent 写入的最可能是它们）：之后的事件（包括 FSEvents
        // 对回填前写入的迟到通知）落到缓存上，不会重读也不会重复发出
        let found = Self.sessionFiles(under: root, depth: format.depth)
        for (rank, file) in found.enumerated() {
            if Task.isCancelled { return }
            await index(file.url, modified: file.modified, size: file.size, remember: rank < Self.liveCacheLimit)
        }
        continuation.yield(.backfillFinished(sessionFiles: found.map(\.url).filter { !excluded.contains($0) }))

        for await paths in watcher.paths {
            if Task.isCancelled { return }
            if paths.contains(root.path) { // 丢事件：整体重扫
                // 与回填一样只记住最近修改的那批：从新到旧全记住会让旧文件把新的挤出缓存
                for (rank, file) in Self.sessionFiles(under: root, depth: format.depth).enumerated() {
                    await index(file.url, modified: file.modified, size: file.size, remember: rank < Self.liveCacheLimit)
                }
                continue
            }
            for path in Set(paths) where Self.isSessionFile(path, under: root, depth: format.depth) {
                await index(URL(filePath: path), modified: nil, remember: true)
            }
        }
    }

    /// 另盯追加的文件：按文件的修改时间留最近写过的 `limit` 个，满了换下最久没写的那个。
    /// 不按被读到的先后：重扫、旧文件的迟到通知都会读到旧文件，它们不该把还在写的会话挤掉。
    private struct Followed {
        let limit: Int
        private var writtenAt: [String: Date] = [:]

        init(limit: Int) { self.limit = limit }

        /// 读到一个文件时记下它的修改时间：返回要不要盯它、换下了哪个。
        mutating func note(_ path: String, writtenAt date: Date) -> (follows: Bool, dropped: String?) {
            if let known = writtenAt[path] {
                writtenAt[path] = max(known, date)
                return (true, nil)
            }
            guard writtenAt.count >= limit else {
                writtenAt[path] = date
                return (true, nil)
            }
            guard let oldest = writtenAt.min(by: { $0.value < $1.value }), oldest.value < date else { return (false, nil) }
            writtenAt[oldest.key] = nil
            writtenAt[path] = date
            return (true, oldest.key)
        }
    }

    private static func isSessionFile(_ path: String, under root: URL, depth: Int) -> Bool {
        let url = URL(filePath: path)
        guard url.pathExtension == "jsonl" else { return false }
        var parent = url
        for _ in 0..<depth { parent = parent.deletingLastPathComponent() }
        return parent.path == root.path
    }

    private static func modified(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 全部会话文件与修改时间、大小，最近修改的在前。
    private static func sessionFiles(under root: URL, depth: Int) -> [(url: URL, modified: Date, size: UInt64?)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(url: URL, modified: Date, size: UInt64?)] = []
        for case let url as URL in walker {
            guard walker.level == depth else { continue }
            walker.skipDescendants()  // 更深的子目录（如 subagents/）不进
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize.map(UInt64.init)))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    /// 最近使用的若干文件从哪接着读。
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
