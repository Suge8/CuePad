#if os(macOS)
import Foundation

/// 启动 `process` 并取它的标准输出与退出码（标准输出由这里接管；标准输入、标准错误由调用方设）。管道在进程运行期间就读：
/// 输出超过管道缓冲（64 KB）时子进程写不进去会卡住，等它退出再读就永远等不到。无法启动、或超过 `timeout`（让它终止）返回 nil。
@concurrent public func runCapturing(_ process: Process, timeout: Duration? = nil) async -> (status: Int32, output: String)? {
    enum Event { case output(Data), exited(Int32), timedOut, idle }
    let out = Pipe()
    process.standardOutput = out
    let (exited, exit) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { exit.yield($0.terminationStatus) }
    do { try process.run() } catch { return nil }
    // 包一层不继承取消的任务：取消调用方不影响进程，超时照样终止它，退出码照实取
    // （withTaskCancellationShield 要 macOS 27，部署目标是 26）
    return await Task { await withTaskGroup(of: Event.self) { group in
        group.addTask { .output(await readToEnd(out.fileHandleForReading)) }
        group.addTask {
            for await code in exited { return .exited(code) }
            return .exited(-1)
        }
        if let timeout {
            group.addTask {
                guard (try? await Task.sleep(for: timeout)) != nil, process.isRunning else { return .idle }
                process.terminate()
                return .timedOut
            }
        }
        var status: Int32 = -1
        var data = Data()
        var timedOut = false
        for await event in group {
            switch event {
            case .output(let bytes): data = bytes
            case .exited(let code):
                status = code
                group.cancelAll()  // 看门狗不必再等
            case .timedOut: timedOut = true
            case .idle: break
            }
        }
        return timedOut ? nil : (status, String(decoding: data, as: UTF8.self))
    } }.value
}

@concurrent private func readToEnd(_ handle: FileHandle) async -> Data {
    (try? handle.readToEnd()) ?? Data()
}
#endif
