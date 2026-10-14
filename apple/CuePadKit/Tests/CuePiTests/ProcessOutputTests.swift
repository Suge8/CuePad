#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 终端跳转和 Pi 检测都靠"起进程、取标准输出"：输出比管道缓冲（64 KB）大时，子进程写不进去就卡住，必须在它运行期间就读。
struct ProcessOutputTests {
    @Test(.timeLimit(.minutes(1))) func outputLargerThanThePipeBufferIsReadInFull() async {
        let result = await LivePiTerminalSystem().run("sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x; exit 3"])
        #expect(result.status == 3 && result.output.count == 300_000)
    }

    /// 检测 Pi 版本时 pi 卡住：到时间就结束它、不等下去。
    @Test(.timeLimit(.minutes(1))) func aStuckProcessIsStoppedAtTheTimeout() async {
        let started = ContinuousClock.now
        #expect(await runCapturing(URL(filePath: "/bin/sleep"), ["30"], timeout: .milliseconds(200)) == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// 超时结束的是起的命令连同它起的子进程：子进程握着输出管道、自己不退，也不让调用方等它。
    @Test(.timeLimit(.minutes(1))) func aTimeoutEndsTheChildrenHoldingTheOutputToo() async throws {
        let marker = try makeTempDirectory().appending(path: "child.pid")
        // 子进程不理 SIGTERM（像 Agent 起的服务），后台跑着、继承了标准输出
        let script = "sh -c \"trap '' TERM; echo \\$\\$ > '\(marker.path)'; sleep 30\" & wait"
        let started = ContinuousClock.now
        #expect(await runCapturing(URL(filePath: "/bin/sh"), ["-c", script], timeout: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
        let child = try #require(pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(child, 0) != 0)
    }
}
#endif
