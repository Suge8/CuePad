#if os(macOS)
import Foundation
import Synchronization

/// 启动 `process` 并取它的标准输出与退出码（标准输出由这里接管）。管道在进程运行期间就读：输出超过管道缓冲（64 KB）时
/// 子进程写不进去会卡住，等它退出再读就永远等不到。无法启动、或超过 `timeout`（让它终止）返回 nil。
func runCapturing(_ process: Process, timeout: Duration? = nil) async -> (status: Int32, output: String)? {
    let out = Pipe()
    process.standardOutput = out
    let (exited, exit) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { exit.yield($0.terminationStatus) }
    do { try process.run() } catch { return nil }
    let timedOut = Mutex(false)
    let watchdog = timeout.map { timeout in
        Task.detached {
            guard (try? await Task.sleep(for: timeout)) != nil, process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
    }
    async let output: Data = withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: (try? out.fileHandleForReading.readToEnd()) ?? Data()) }
    }
    var status: Int32 = -1
    for await code in exited {
        status = code
        break
    }
    watchdog?.cancel()
    let data = await output
    return timedOut.withLock { $0 } ? nil : (status, String(decoding: data, as: UTF8.self))
}
#endif
