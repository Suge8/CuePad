#if os(macOS)
import Foundation

/// 跑一个命令，取它的标准输出与退出码。用 `LineProcess` 起（自成进程组，标准输入一开始就关上，标准错误不要）：
/// 输出在它运行期间就读（超过管道缓冲时子进程写不进去会卡住，等它退出再读就永远等不到），按行拼回，空行与行尾的 \r 不保留。
/// 超过 `timeout`：结束它连同它起的整组进程（不理 SIGTERM 的、握着输出管道的子进程也一样），返回 nil；起不来也返回 nil。
/// 取消调用方不影响进程：超时照样结束它，退出码照实取。`environment` 是完整的环境（不继承本进程的）。
@concurrent public func runCapturing(
    _ executable: URL, _ arguments: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment,
    directory: URL? = nil, timeout: Duration? = nil
) async -> (status: Int32, output: String)? {
    guard let process = try? LineProcess(executable: executable, arguments: arguments, directory: directory, environment: environment) else {
        return nil
    }
    process.closeInput()
    // 包一层不继承取消的任务（withTaskCancellationShield 要 macOS 27，部署目标是 26）
    return await Task {
        let watchdog = timeout.map { limit in
            Task {
                guard (try? await Task.sleep(for: limit)) != nil, !process.hasExited else { return false }
                process.terminate()
                return true
            }
        }
        var lines: [String] = []
        for await line in process.lines { lines.append(String(decoding: line, as: UTF8.self)) }
        let status = await process.exitCode()
        watchdog?.cancel()
        guard await watchdog?.value != true else { return nil }
        return (status, lines.joined(separator: "\n"))
    }.value
}
#endif
