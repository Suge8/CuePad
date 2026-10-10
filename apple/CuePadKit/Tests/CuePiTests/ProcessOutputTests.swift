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
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        #expect(await runCapturing(process, timeout: .milliseconds(200)) == nil)
        #expect(!process.isRunning)
    }
}
#endif
