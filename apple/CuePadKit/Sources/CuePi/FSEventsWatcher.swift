import CoreServices
import Foundation

/// 递归监听目录，事件流里是变化路径。发生丢事件/需要重扫时，流里出现根路径本身。
/// 不要依赖创建事件：FSEvents 不报告"仅 bind、没有后续属性变更"的 socket 文件创建。
final class FSEventsWatcher: @unchecked Sendable {
    let paths: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation
    private var stream: FSEventStreamRef?
    private let root: String
    private let queue = DispatchQueue(label: "cuepi.fsevents")

    init(root: URL) {
        self.root = root.path
        (paths, continuation) = AsyncStream.makeStream()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info!).takeUnretainedValue()
            let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let needsRescan = (0..<count).contains { eventFlags[$0] & lost != 0 }
            watcher.continuation.yield(needsRescan ? [watcher.root] : changed)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        FSEventStreamSetDispatchQueue(stream!, queue)
        FSEventStreamStart(stream!)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }

    deinit { stop() }
}
