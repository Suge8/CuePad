#if os(macOS)
import Darwin
import Foundation
import Synchronization

extension ChildProcess {
    /// 子进程标准错误的末尾（至多 `limit`），给退出原因用：读事件读到 EOF 或 `stop()`。
    /// 退出事件可能先于最后几块输出被读到：报退出前 `flush()` 在读的那条队列上把管道里已有的读完（`FIONREAD` 量出多少读多少，
    /// 不阻塞、不改描述符的阻塞属性——脱离 App 的进程的看守与它共用这根管道的读端，见 `ChildProcess+Plumbing` 的 `relay`）。
    final class ErrorTail: Sendable {
        private static let limit = 4096
        /// `<sys/filio.h>` 的 `FIONREAD`（`_IOR('f', 127, int)`）：宏没导入 Swift
        private static let bytesAvailable: UInt = 0x4004_667F
        private let queue = DispatchQueue(label: "cuepad.child.errors")
        private let source: any DispatchSourceRead
        private let fd: Int32
        private let tail = Mutex(Data())

        init(_ fd: Int32) {
            self.fd = fd
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let source = source
            source.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: Self.limit)
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { return }
                guard n > 0 else { return source.cancel() }
                self?.append(buffer[0..<n])
            }
            source.setCancelHandler { close(fd) }
            source.resume()
        }

        /// 读完管道里此刻已有的输出（进程已退出时就是它写过的全部）。
        func flush() {
            queue.sync {
                guard !source.isCancelled else { return }
                var available: Int32 = 0
                while ioctl(fd, Self.bytesAvailable, &available) == 0, available > 0 {
                    var buffer = [UInt8](repeating: 0, count: Int(available))
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return }
                    append(buffer[0..<n])
                }
            }
        }

        /// 不再读（关掉本进程这端）；之后的输出由别的读者接走或进程收到 EPIPE。
        func stop() { source.cancel() }

        /// 去掉首尾空白的末尾。
        var text: String {
            String(decoding: tail.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func append(_ bytes: ArraySlice<UInt8>) {
            tail.withLock {
                $0.append(contentsOf: bytes)
                if $0.count > Self.limit { $0 = Data($0.suffix(Self.limit)) }
            }
        }
    }
}
#endif
