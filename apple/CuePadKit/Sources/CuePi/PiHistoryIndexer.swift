#if os(macOS)
import Foundation

/// 后台索引 Pi 会话目录：先按修改时间倒序回填（最近的会话最先可用），发出 `backfillFinished` 后
/// 用 FSEvents 跟随文件变化，只读新增字节。
///
/// 不持有全部检查点：起点由调用方通过 `checkpoint` 提供（App 层从 Store 读），每个 `updated`
/// 里带回新检查点由调用方持久化。索引器只对最近修改/最近被触碰的若干文件在内存里保留检查点，
/// 这样调用方持久化滞后时增量也不会退化成重读。
public struct PiHistoryIndexer: Sendable {
    private let root: URL
    private let transcriptWindow: TimeInterval
    private let checkpoint: @Sendable (URL) async -> PiHistoryCheckpoint?

    private static let liveCacheLimit = 64

    /// - Parameter transcriptWindow: 首次读（没有检查点）时只为这么久之内修改过的会话文件解析对话（按修改时间，不读内容），
    ///   更早的只读摘要（见 `PiHistory.index(file:from:transcript:)`）。
    public init(
        root: URL = PiPaths().sessionsDirectory, transcriptWindow: TimeInterval = .infinity,
        checkpoint: @escaping @Sendable (URL) async -> PiHistoryCheckpoint?
    ) {
        self.root = root
        self.transcriptWindow = transcriptWindow
        self.checkpoint = checkpoint
    }

    /// 结束（取消订阅）时停止后台任务。会话目录可以还不存在（先装 CuePad、后装 Pi）或被删再建，见 `FSEventsWatcher`。
    public func events() -> AsyncStream<PiHistoryEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) { await run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<PiHistoryEvent>.Continuation) async {
        // FSEvents 报告真实路径；统一用真实路径，回填与增量的文件 URL 才一致（目录还不存在时解析其上层）
        let root = FSEventsWatcher.resolve(self.root)
        let watcher = FSEventsWatcher(root: root) // 先开始监听：回填期间的变化不会丢
        defer { watcher.stop() }
        var live = LiveCache(limit: Self.liveCacheLimit)

        func index(_ file: URL, modified: Date?, remember: Bool) async {
            let base: PiHistoryCheckpoint?
            if let cached = live[file] { base = cached } else { base = await checkpoint(file) }
            let recent = (modified ?? Self.modified(file)).map { $0 > Date.now.addingTimeInterval(-transcriptWindow) } ?? true
            // 文件已被删除/尚未落盘等：跳过，等下一次变化
            guard let update = try? PiHistory.index(file: file, from: base, transcript: recent) else { return }
            if remember { live[file] = update.checkpoint }
            if update.bytesRead > 0 || base == nil { continuation.yield(.updated(update)) }
        }

        // 回填时记住最近修改的那批文件（正在被 Pi 写入的最可能是它们）：之后的事件（包括 FSEvents
        // 对回填前写入的迟到通知）落到缓存上，不会重读也不会重复发出
        let files = Self.sessionFiles(under: root)
        for (rank, file) in files.enumerated() {
            if Task.isCancelled { return }
            await index(file.url, modified: file.modified, remember: rank < Self.liveCacheLimit)
        }
        continuation.yield(.backfillFinished(sessionFiles: files.map(\.url)))

        for await paths in watcher.paths {
            if Task.isCancelled { return }
            if paths.contains(root.path) { // 丢事件：整体重扫
                for file in Self.sessionFiles(under: root) { await index(file.url, modified: file.modified, remember: true) }
                continue
            }
            for path in Set(paths) where Self.isSessionFile(path, under: root) {
                await index(URL(filePath: path), modified: nil, remember: true)
            }
        }
    }

    /// 会话文件只有 `<root>/<项目目录>/*.jsonl`，与 Pi 自己的会话列表一致；更深的（如 FireCode 子代理的
    /// `<项目目录>/subagents/*.jsonl`）不是会话列表里的会话。
    private static func isSessionFile(_ path: String, under root: URL) -> Bool {
        let url = URL(filePath: path)
        // FSEvents 报 /private/var/…，解析符号链接后的 root 是 /var/…：两边都解析再比
        return url.pathExtension == "jsonl"
            && url.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path
    }

    private static func modified(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 全部会话文件与修改时间，最近修改的在前。
    private static func sessionFiles(under root: URL) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in walker {
            guard walker.level == 2 else { continue }
            walker.skipDescendants()  // 项目目录里的子目录（如 subagents/）不进
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
