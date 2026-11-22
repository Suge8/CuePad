#if os(macOS)
import CueStore
import Foundation
import Synchronization

public struct HistoryIndexer: Sendable {
    private let agent: AgentKind
    private let format: SessionFileFormat
    private let root: URL
    private let transcriptWindow: TimeInterval
    private let files: AttachmentFiles
    private let start: @Sendable (URL) async -> HistoryStart?

    private static let liveCacheLimit = 64

    public init?(
        agent: AgentKind, paths: AgentPaths, transcriptWindow: TimeInterval = .infinity, files: AttachmentFiles,
        start: @escaping @Sendable (URL) async -> HistoryStart?
    ) {
        guard let format = agent.facts.sessionFiles else { return nil }
        self.agent = agent
        self.format = format
        root = format.directory(paths)
        self.transcriptWindow = transcriptWindow
        self.files = files
        self.start = start
    }

    public func events(
        following liveFiles: some AsyncSequence<Set<URL>, Never> & Sendable, scope: HistoryScope
    ) -> AsyncStream<HistoryEvent> {
        AsyncStream { continuation in
            let task = Task(priority: .utility) { await run(continuation, following: liveFiles, scope: scope) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent private func run(
        _ continuation: AsyncStream<HistoryEvent>.Continuation, following liveFiles: some AsyncSequence<Set<URL>, Never> & Sendable,
        scope: HistoryScope
    ) async {
        let root = self.root.realPath
        let follower = FileFollower()
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
        defer { following.cancel() }
        var live = LiveCache(limit: Self.liveCacheLimit)
        var excluded: Set<URL> = []

        func index(_ file: URL, modified: Date?, size: UInt64? = nil, remember: Bool) async {
            let base: HistoryStart?
            if let cached = live[file] { base = cached } else { base = await start(file) }
            let written = modified ?? Self.modified(file)
            let recent = written.map { $0 > Date.now.addingTimeInterval(-transcriptWindow) } ?? true
            let wanted = recent || base?.hasTranscript == true
            let from = wanted && base?.hasTranscript != true ? nil : base?.checkpoint
            let checkpoint: HistoryCheckpoint
            var update: HistoryUpdate?
            let sidecarWritten = format.sidecar.flatMap { Self.modified($0.file(file)) }
            if let from, let size, let written, from.isCurrent(size: size, modified: written, sidecarModified: sidecarWritten) {
                checkpoint = from
            } else {
                guard let read = try? History.index(file: file, agent: agent, from: from, transcript: wanted, modified: written, files: files)
                else { return }
                checkpoint = read.checkpoint
                update = read
            }
            if remember { live[file] = HistoryStart(checkpoint: checkpoint, hasTranscript: wanted || base?.hasTranscript == true) }
            if checkpoint.excluded {
                excluded.insert(file)
                return
            }
            guard format.isSession(checkpoint) else { return }
            guard let update, update.bytesRead > 0 || update.renamed
                || base?.checkpoint.map({ $0.modified != checkpoint.modified || $0.sidecarModified != checkpoint.sidecarModified }) ?? true
            else { return }
            continuation.yield(.updated(update))
        }

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
            walker.skipDescendants()
            guard format.matches(url) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize.map(UInt64.init)))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    private struct LiveCache {
        let limit: Int
        private var values: [URL: HistoryStart] = [:]
        private var order: [URL] = []

        subscript(file: URL) -> HistoryStart? {
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
