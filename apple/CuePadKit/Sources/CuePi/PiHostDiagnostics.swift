#if os(macOS)
import CueStore
import Darwin
import Foundation
import OSLog

/// RPC stdout 必须持续消费；不能用 App 持有的管道，否则 App 重开会令脱离它的 Pi 写入失败。
/// 写进无名临时文件，以写事件增量读取错误；最后一个描述符关闭即释放，不留下持久对话副本。
final class PiHostDiagnostics: Sendable {
    let descriptor: Int32
    private let source: DispatchSourceFileSystemObject

    init() throws {
        descriptor = try ChildProcess.scratchFile()
        let core = Reader(descriptor)
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend], queue: DispatchQueue(label: "cuepad.pi.diagnostics"))
        source.setEventHandler { core.drain() }
        source.setCancelHandler {
            core.drain()
            close(core.descriptor)
        }
        source.resume()
    }

    func finish() { source.cancel() }
    deinit { source.cancel() }

    /// 只在 source 的串行队列上读取。
    private final class Reader: @unchecked Sendable {
        private static let log = Logger(subsystem: AppIdentity.id, category: "pi-host")
        let descriptor: Int32
        private var offset: off_t = 0
        private let lines = LineReader()

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        func drain() {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = pread(descriptor, &buffer, buffer.count, offset)
                if count < 0 {
                    Self.log.error("读取托管 Pi 的 RPC 诊断失败：\(errno)")
                    return
                }
                if count == 0 { return }
                offset += off_t(count)
                for line in lines.split(Data(buffer.prefix(count))) { record(line) }
            }
        }

        private func record(_ line: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                Self.log.error("托管 Pi 的非 RPC 输出：\(String(decoding: line, as: UTF8.self))")
                return
            }
            let type = json["type"] as? String
            guard type == "extension_error" || type == "error" || (type == "response" && json["success"] as? Bool == false) else { return }
            Self.log.error("托管 Pi 的 RPC 诊断：\(String(decoding: line, as: UTF8.self))")
        }
    }
}
#endif
