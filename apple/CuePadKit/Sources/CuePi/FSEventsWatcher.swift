#if os(macOS)
import CoreServices
import Foundation

/// 递归监听目录，事件流里是变化路径。发生丢事件/需要重扫时，流里出现根路径本身。
/// 不要依赖创建事件：FSEvents 不报告"仅 bind、没有后续属性变更"的 socket 文件创建。
final class FSEventsWatcher: @unchecked Sendable {
    let paths: AsyncStream<[String]>
    private let target: Target
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "cuepi.fsevents")

    /// 回调要用到的东西。由事件流经 retain/release 自己持有，流释放前一直有效：
    /// 停止与释放观察器时，已经排进队列的回调也不会碰到已释放的对象。
    private final class Target: @unchecked Sendable {
        let root: String
        let continuation: AsyncStream<[String]>.Continuation
        init(root: String, continuation: AsyncStream<[String]>.Continuation) {
            self.root = root
            self.continuation = continuation
        }
    }

    init(root: URL) {
        let (paths, continuation) = AsyncStream<[String]>.makeStream()
        self.paths = paths
        target = Target(root: root.path, continuation: continuation)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(target).toOpaque(),
            retain: { info in
                _ = Unmanaged<Target>.fromOpaque(info!).retain()
                return info
            },
            release: { info in Unmanaged<Target>.fromOpaque(info!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            let target = Unmanaged<Target>.fromOpaque(info!).takeUnretainedValue()
            let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let needsRescan = (0..<count).contains { eventFlags[$0] & lost != 0 }
            target.continuation.yield(needsRescan ? [target.root] : changed)
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
        target.continuation.finish()
    }

    deinit { stop() }
}
#endif
