#if os(macOS)
import CoreServices
import Foundation

/// 递归监听目录，事件流里是变化路径。发生丢事件/需要重扫时，流里出现根路径本身。
/// 目录可以还不存在（先装 CuePad、后装 Pi），也可以被删掉再建：不存在时盯着最近的已存在上层目录，等它出现再切过去，
/// 切过去时给出一次根路径（整体重扫，切换前写进去的文件不会漏）；根目录被删掉再建也一样。
/// 不要依赖创建事件：FSEvents 不报告"仅 bind、没有后续属性变更"的 socket 文件创建。
final class FSEventsWatcher: Sendable {
    let paths: AsyncStream<[String]>
    private let core: Core

    init(root: URL) {
        let (paths, continuation) = AsyncStream<[String]>.makeStream()
        self.paths = paths
        core = Core(root: Self.resolve(root).path, continuation: continuation)
        core.queue.sync { core.arm() }  // 同步开始监听：调用方随后的回填期间的变化不会丢
    }

    func stop() {
        core.queue.sync { core.stop() }
    }

    deinit { stop() }

    /// 解析符号链接后的真实路径（FSEvents 报告真实路径）；路径还不存在时解析最近的已存在上层，再接上其余部分。
    static func resolve(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
    }

    /// 监听状态，只在 `queue` 上访问。由事件流（retain/release）与上层目录的监听回调持有，`stop()` 后释放。
    private final class Core: @unchecked Sendable {
        let root: String
        let continuation: AsyncStream<[String]>.Continuation
        let queue = DispatchQueue(label: "cuepi.fsevents")
        private var stream: FSEventStreamRef?
        private var ancestor: DispatchSourceFileSystemObject?
        private var stopped = false

        init(root: String, continuation: AsyncStream<[String]>.Continuation) {
            self.root = root
            self.continuation = continuation
        }

        /// 根目录在就监听它，不在就盯着最近的已存在上层目录。
        /// `rescan`：切换监听时给出根路径（整体重扫）。必须在新的事件流开始之后给：拆掉旧流会丢掉它还没送出的事件，
        /// 新流只报开始之后的变化；先开始再重扫，之前写进去的由重扫读到，之后的由新流报告，中间没有空档。
        func arm(rescan: Bool = false) {
            guard !stopped else { return }
            disarm()
            if Self.isDirectory(root) {
                startStream()
                if rescan { continuation.yield([root]) }
            } else {
                watchNearestAncestor()
            }
        }

        func stop() {
            stopped = true
            disarm()
            continuation.finish()
        }

        private func disarm() {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            ancestor?.cancel()
            ancestor = nil
        }

        private func startStream() {
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    _ = Unmanaged<Core>.fromOpaque(info!).retain()
                    return info
                },
                release: { info in Unmanaged<Core>.fromOpaque(info!).release() },
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                let core = Unmanaged<Core>.fromOpaque(info!).takeUnretainedValue()
                let flags = (0..<count).map { eventFlags[$0] }
                // 根目录被删或改名：重新判断（已经再建出来就对新目录开流，否则盯上层目录），切换后重扫
                if flags.contains(where: { $0 & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }) {
                    core.queue.async { core.arm(rescan: true) }  // 不在事件流自己的回调里拆掉它
                    return
                }
                let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
                let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                core.continuation.yield(flags.contains { $0 & lost != 0 } ? [core.root] : changed)
            }
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
            else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
        }

        /// 只看这个上层目录本身的增删（kqueue，不递归），下一级出现或它自己被删时重新判断。
        private func watchNearestAncestor() {
            let directory = nearestExistingAncestor()
            let descriptor = open(directory, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [self] in arm(rescan: true) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            ancestor = source
            // 判断与开始盯之间下一级可能已经建出来
            if nearestExistingAncestor() != directory { arm(rescan: true) }
        }

        /// 只认目录：路径上有同名普通文件时盯它所在的目录，那个文件被换成目录时才收得到通知。
        private func nearestExistingAncestor() -> String {
            var url = URL(filePath: root)
            while !Self.isDirectory(url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
            return url.path
        }

        private static func isDirectory(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
#endif
