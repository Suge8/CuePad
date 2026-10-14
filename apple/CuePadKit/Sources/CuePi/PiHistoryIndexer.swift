#if os(macOS)
import CueStore
import Foundation

/// 后台索引一个 Agent 的会话目录（Pi、Claude Code、Codex 的会话文件）：先按修改时间倒序回填（最近的会话最先可用），发出 `backfillFinished` 后
/// 用 FSEvents 跟随文件变化，只读新增字节；最近写过的几个文件另盯追加（开着写的文件 FSEvents 只在关闭时报，见 `FSEventsWatcher.follow`）。
///
/// 不持有全部检查点：起点由调用方通过 `checkpoint` 提供（App 层从 Store 读），每个 `updated`
/// 里带回新检查点由调用方持久化。索引器只对最近修改/最近被触碰的若干文件在内存里保留检查点，
/// 这样调用方持久化滞后时增量也不会退化成重读。
public struct PiHistoryIndexer: Sendable {
    private let root: URL
    private let agent: AgentKind
    private let transcriptWindow: TimeInterval
    private let files: AttachmentFiles
    private let checkpoint: @Sendable (URL) async -> PiHistoryCheckpoint?

    private static let liveCacheLimit = 64
    /// 另盯追加的文件数：每个占一个文件描述符，GUI 应用默认只有 256 个
    private static let followLimit = 8

    /// - Parameter transcriptWindow: 首次读（没有检查点）时只为这么久之内修改过的会话文件解析对话（按修改时间，不读内容），
    ///   更早的只读摘要（见 `PiHistory.index(file:from:transcript:files:)`）。
    /// - Parameter files: 你的消息里的图片存进的附件目录。
    public init(
        root: URL = PiPaths().sessionsDirectory, agent: AgentKind = .pi, transcriptWindow: TimeInterval = .infinity, files: AttachmentFiles,
        checkpoint: @escaping @Sendable (URL) async -> PiHistoryCheckpoint?
    ) {
        self.root = root
        self.agent = agent
        self.transcriptWindow = transcriptWindow
        self.files = files
        self.checkpoint = checkpoint
    }

    /// 结束（取消订阅）时停止后台任务。会话目录可以还不存在（先装 CuePad、后装 Pi）或被删再建，见 `FSEventsWatcher`。
    public func events() -> AsyncStream<PiHistoryEvent> {
        AsyncStream { continuation in
            let task = Task(priority: .utility) { await run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent private func run(_ continuation: AsyncStream<PiHistoryEvent>.Continuation) async {
        // FSEvents 报告真实路径；统一用真实路径，回填与增量的文件 URL 才一致（目录还不存在时解析其上层）
        let root = FSEventsWatcher.resolve(self.root)
        let watcher = FSEventsWatcher(root: root) // 先开始监听：回填期间的变化不会丢
        defer { watcher.stop() }
        var live = LiveCache(limit: Self.liveCacheLimit)
        var excluded: Set<URL> = []
        var followed: [String] = []

        /// 刚写过的文件另盯追加，只留最近的 `followLimit` 个
        func follow(_ file: URL) {
            followed.removeAll { $0 == file.path }
            followed.append(file.path)
            watcher.follow(file.path)
            if followed.count > Self.followLimit { watcher.unfollow(followed.removeFirst()) }
        }

        func index(_ file: URL, modified: Date?, remember: Bool, follows: Bool = true) async {
            let base: PiHistoryCheckpoint?
            if let cached = live[file] { base = cached } else { base = await checkpoint(file) }
            let recent = (modified ?? Self.modified(file)).map { $0 > Date.now.addingTimeInterval(-transcriptWindow) } ?? true
            // 文件已被删除/尚未落盘等：跳过，等下一次变化
            guard let update = try? PiHistory.index(file: file, agent: agent, from: base, transcript: recent, files: files) else { return }
            if remember { live[file] = update.checkpoint }
            if update.checkpoint.excluded == true {
                excluded.insert(file)
                return
            }
            if follows { follow(file) }
            if update.bytesRead > 0 || base == nil { continuation.yield(.updated(update)) }
        }

        // 回填时记住最近修改的那批文件（正在被 Pi 写入的最可能是它们）：之后的事件（包括 FSEvents
        // 对回填前写入的迟到通知）落到缓存上，不会重读也不会重复发出
        let depth = Self.depth(of: agent)
        let found = Self.sessionFiles(under: root, depth: depth)
        for (rank, file) in found.enumerated() {
            if Task.isCancelled { return }
            await index(file.url, modified: file.modified, remember: rank < Self.liveCacheLimit, follows: rank < Self.followLimit)
        }
        continuation.yield(.backfillFinished(sessionFiles: found.map(\.url).filter { !excluded.contains($0) }))

        for await paths in watcher.paths {
            if Task.isCancelled { return }
            if paths.contains(root.path) { // 丢事件：整体重扫
                for (rank, file) in Self.sessionFiles(under: root, depth: depth).enumerated() {
                    await index(file.url, modified: file.modified, remember: true, follows: rank < Self.followLimit)
                }
                continue
            }
            for path in Set(paths) where Self.isSessionFile(path, under: root, depth: depth) {
                await index(URL(filePath: path), modified: nil, remember: true)
            }
        }
    }

    /// 会话文件在 `root` 下第几层，与各家自己的会话列表一致：Pi 与 Claude Code 是 `<root>/<项目目录>/*.jsonl`（更深的，如子代理的
    /// `<项目目录>/…/subagents/*.jsonl`，不是会话列表里的会话）；Codex 是 `<root>/YYYY/MM/DD/rollout-*.jsonl`。
    private static func depth(of agent: AgentKind) -> Int { agent == .codex ? 4 : 2 }

    private static func isSessionFile(_ path: String, under root: URL, depth: Int) -> Bool {
        let url = URL(filePath: path)
        guard url.pathExtension == "jsonl" else { return false }
        var parent = url
        for _ in 0..<depth { parent = parent.deletingLastPathComponent() }
        // FSEvents 报 /private/var/…，解析符号链接后的 root 是 /var/…：两边都解析再比
        return parent.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path
    }

    private static func modified(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 全部会话文件与修改时间，最近修改的在前。
    private static func sessionFiles(under root: URL, depth: Int) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in walker {
            guard walker.level == depth else { continue }
            walker.skipDescendants()  // 更深的子目录（如 subagents/）不进
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.map { (url: $0.0, modified: $0.1) }
    }

    /// 最近使用的若干文件的检查点。
    private struct LiveCache {
        let limit: Int
        private var values: [URL: PiHistoryCheckpoint] = [:]
        private var order: [URL] = []

        subscript(file: URL) -> PiHistoryCheckpoint? {
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
