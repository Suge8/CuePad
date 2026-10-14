#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 起进程取输出（Pi 检测、终端跳转、登录检测都经 `ChildProcess.run`）的边界契约。
struct ChildProcessTests {
    /// 输出比管道缓冲（64 KB）大时，子进程写不进去就卡住，必须在它运行期间就读。
    @Test(.timeLimit(.minutes(1))) func outputLargerThanThePipeBufferIsReadInFull() async {
        let result = await ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero | tr '\\0' x; exit 3"])
        #expect(result?.status == 3 && result?.output.count == 300_000)
    }

    /// 卡住的进程（连 SIGTERM 也不理）到时间就结束它、不等下去；取消调用方不撤掉超时，也不拿取消当退出码。
    @Test(.timeLimit(.minutes(1))) func aStuckProcessIsStoppedAtTheTimeoutEvenWhenTheCallerIsCancelled() async throws {
        let started = ContinuousClock.now
        let call = Task { await ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; sleep 30"], timeout: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        #expect(await call.value == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// 子进程（与它再起的进程）按默认处置收信号：本进程忽略或屏蔽了的信号不带过去，
    /// 否则 Claude Code 收到结束信号不走、只能 SIGKILL，收件箱 socket 就留在 /tmp/cc-socks。
    @Test(.timeLimit(.minutes(1))) func aChildEndsOnSIGTERMEvenIfThisProcessIgnoresIt() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        let child = try ChildProcess(URL(filePath: "/bin/sleep"), ["30"], placement: .group)
        signal(SIGTERM, previous)

        kill(child.pid, SIGTERM)
        #expect(await child.exited(within: .seconds(5)))
        child.end()
    }
}
#endif
