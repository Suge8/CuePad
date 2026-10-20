#if os(macOS)
import Foundation

extension URL {
    /// 解析符号链接后的真实路径（`realpath`：`/tmp` 是 `/private/tmp`），目录里列出来的、Codex 信任钩子认的都是它；
    /// 路径还不存在时解析最近的已存在上层，再接上其余部分。不用 `resolvingSymlinksInPath`：它会把 `/private` 又去掉。
    var realPath: URL {
        guard let resolved = Darwin.realpath(path, nil) else {
            let parent = deletingLastPathComponent()
            return parent.path == path ? self : parent.realPath.appending(path: lastPathComponent)
        }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }
}

/// 盯一组文件（kqueue，当场）：每次写入、追加时流里出现它的路径。还没建出来的（Pi 第一条回答落盘前不建会话文件，连所在目录也可能还没有）
/// 盯最近的已存在上层目录，一级级往下，建出来时切过去并报一次；被删或换掉后盯同一路径上的新文件。
/// 不用 FSEvents：fseventsd 转发的事件实测中位晚 3 秒、负载高时晚到 5 分多钟，几次写并成一次，开着写的文件只在关闭时报。
/// 一个文件一个文件描述符（App 启动时放宽了上限）。
final class FileFollower: Sendable {
    let paths: AsyncStream<String>
    private let core: Core

    init() {
        let (paths, continuation) = AsyncStream<String>.makeStream()
        self.paths = paths
        core = Core(continuation: continuation)
    }

    /// 盯的文件换成 `paths`（真实路径）。新加进来的已经在了就报一次（盯上之前写进去的也读到），不再盯的也报一次（读到最后写下的）。
    func follow(only paths: Set<String>) {
        core.queue.sync { core.follow(only: paths) }
    }

    func stop() {
        core.queue.sync { core.stop() }
    }

    deinit { stop() }

    /// 只在 `queue` 上访问。
    private final class Core: @unchecked Sendable {
        let continuation: AsyncStream<String>.Continuation
        let queue = DispatchQueue(label: "cuepi.follow")
        /// 每个要盯的文件一个源：文件在时盯文件本身，还没建出来时盯最近的已存在上层目录
        private var files: [String: DispatchSourceFileSystemObject] = [:]
        private var stopped = false

        init(continuation: AsyncStream<String>.Continuation) {
            self.continuation = continuation
        }

        func follow(only paths: Set<String>) {
            guard !stopped else { return }
            for path in Set(files.keys).subtracting(paths) {
                files.removeValue(forKey: path)?.cancel()
                continuation.yield(path)
            }
            for path in paths where files[path] == nil { descend(path) }
        }

        func stop() {
            stopped = true
            for source in files.values { source.cancel() }
            files = [:]
            continuation.finish()
        }

        /// 盯上文件本身就报一次。
        private func descend(_ path: String) {
            if arm(path) { continuation.yield(path) }
        }

        /// 盯上一个文件，返回盯上的是不是文件本身。
        private func arm(_ path: String) -> Bool {
            files.removeValue(forKey: path)?.cancel()
            guard !stopped else { return false }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor < 0 else {
                files[path] = source(descriptor, [.write, .extend, .delete, .rename]) { [self] events in
                    if !events.isDisjoint(with: [.delete, .rename]) { _ = arm(path) }
                    continuation.yield(path)
                }
                return true
            }
            let directory = Self.nearestDirectory(above: path)
            let watched = open(directory, O_EVTONLY)
            guard watched >= 0 else { return false }
            files[path] = source(watched, [.write]) { [self] _ in descend(path) }
            // 判断与开始盯之间下面已经建出来（目录或文件本身）：那一下变化盯不到了
            if FileManager.default.fileExists(atPath: path) || Self.nearestDirectory(above: path) != directory { descend(path) }
            return false
        }

        private func source(
            _ descriptor: Int32, _ mask: DispatchSource.FileSystemEvent, _ handle: @escaping (DispatchSource.FileSystemEvent) -> Void
        ) -> DispatchSourceFileSystemObject {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
            source.setEventHandler { [unowned source] in handle(source.data) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            return source
        }

        private static func nearestDirectory(above path: String) -> String {
            var directory = (path as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            while !(FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue), directory != "/" {
                directory = (directory as NSString).deletingLastPathComponent
            }
            return directory
        }
    }
}
#endif
