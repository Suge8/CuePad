#if os(macOS)
import CueStore
import Foundation

extension OpenCodeClient {
    /// 起一台只给 CuePad 用的服务（Cue 的大脑、问模型）：`opencode serve --stdio`，自成进程组，生命随标准输入（关了就退，
    /// `ChildProcess.stop` 先关输入；后台服务那样的 `opencode serve` 收到 SIGTERM 退不干净）。不复用用户的后台服务：
    /// 内联配置（`OPENCODE_CONFIG_CONTENT`）只有起服务时给得进去。
    /// - 端口由系统挑（`--port 0`；缺省从 4096 往上找空的），密码每次新给（`OPENCODE_SERVER_PASSWORD`）；
    /// - 不盯文件（`OPENCODE_DISABLE_FILEWATCHER`）：它盯着家目录与配置目录，关输入后要等这些盯守逐个停下，
    ///   实测 2.1.4 退出从 0.03 秒拖到 3～60 秒，启动也慢几秒；不自动更新。
    ///
    /// `environment` 是完整的环境。没握手就退出抛 `launchFailed`（退出原因），超时抛 `launchTimedOut`，起了的进程都已停掉。
    static func serve(
        _ executable: URL, environment: [String: String], directory: URL
    ) async throws -> (process: ChildProcess, client: OpenCodeClient) {
        let password = UUID().uuidString
        let environment = environment.merging(
            ["OPENCODE_SERVER_PASSWORD": password, "OPENCODE_DISABLE_FILEWATCHER": "1", "OPENCODE_DISABLE_AUTOUPDATE": "1"]) { $1 }
        let process = try await ChildProcess(
            executable, ["serve", "--stdio", "--port", "0"], directory: directory, environment: environment, placement: .group,
            input: .pipe, output: .lines)
        let output = process.output
        let handshake: Data?
        do {
            handshake = try await withDeadline(AgentTimeouts.launch, orThrow: AgentRuntimeError.launchTimedOut(.opencode)) {
                await output.first { _ in true }
            }
        } catch {
            await process.stop()
            throw error
        }
        guard let info = handshake.flatMap({ OpenCodeServiceInfo.stdio($0, pid: process.pid, password: password) }) else {
            let reason = handshake == nil ? await process.exited() : nil
            await process.stop()
            throw AgentRuntimeError.launchFailed(.opencode, reason?.text ?? String(localized: "opencode serve --stdio 没有报出地址"))
        }
        return (process, OpenCodeClient(info))
    }
}
#endif
