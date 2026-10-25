#if os(macOS)
import CueTestSupport
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
        let started = try makeTempDirectory().appending(path: "started")
        let call = Task { await ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; touch '\(started.path)'; sleep 30"], timeout: .seconds(1)) }
        try await eventually("命令跑起来了") { !fileGone(started) }
        call.cancel()
        #expect(await call.value == nil)
    }

    /// 超时结束的是起的命令连同它起的子进程：子进程握着输出管道、自己不退，也不让调用方等它。
    @Test(.timeLimit(.minutes(1))) func aTimeoutEndsTheChildrenHoldingTheOutputToo() async throws {
        let marker = try makeTempDirectory().appending(path: "child.pid")
        // 子进程不理 SIGTERM（像 Agent 起的服务），后台跑着、继承了标准输出
        let script = "sh -c \"trap '' TERM; echo \\$\\$ > '\(marker.path)'; sleep 30\" & wait"
        #expect(await ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", script], timeout: .milliseconds(300)) == nil)
        let child = try #require(pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await eventually("子进程也结束了") { kill(child, 0) != 0 }
    }

    /// 子进程（与它再起的进程）按默认处置收信号：本进程忽略或屏蔽了的信号不带过去，
    /// 否则 Claude Code 收到结束信号不走、只能 SIGKILL，收件箱 socket 就留在 /tmp/cc-socks。
    @Test(.timeLimit(.minutes(1))) func aChildEndsOnSIGTERMEvenIfThisProcessIgnoresIt() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        let child = try await ChildProcess(URL(filePath: "/bin/sleep"), ["30"], placement: .group)
        signal(SIGTERM, previous)

        kill(child.pid, SIGTERM)
        #expect(await child.exited(within: .seconds(5)))
        child.end()
    }

    /// 后台托管的进程在认领之前，起它的一方没了（App 退出、更新、崩溃，这里是起它的对象释放了）就随之结束，连 SIGTERM 也不理的也不留下：
    /// 不然起到一半 App 就没了、扩展又没接手的 Pi 会一直空转（10-21 测量实例留下的 25 个孤儿）。认领之后照常活着由
    /// `RealHostTests.aHostedSessionOutlivesCuePadAndIsSeenAgainByTheNextOne` 证明。
    @Test(.timeLimit(.minutes(1))) func aDetachedProcessNobodyClaimedEndsWithItsLauncher() async throws {
        let started = try makeTempDirectory().appending(path: "started")
        var child: ChildProcess? = try await ChildProcess(
            URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; touch '\(started.path)'; exec sleep 300"], placement: .detached, input: .lifeline)
        let pid = try #require(child?.pid)
        defer { kill(pid, SIGKILL) }  // 见红时别留下
        try await eventually("它跑起来了、不理 SIGTERM") { !fileGone(started) }
        child = nil
        try await eventually("没认领的进程随起它的一方结束", timeout: .seconds(15)) { kill(pid, 0) != 0 }
    }
}
#endif
