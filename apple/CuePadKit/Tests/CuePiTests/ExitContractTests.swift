#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 子进程超时的边界契约。
@MainActor
struct ExitContractTests {
    /// 取消调用方不撤掉超时：超时到了照样终止进程并返回 nil，不拿取消当退出码。
    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerKeepsTheTimeout() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["5"]
        let call = Task { await runCapturing(process, timeout: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        let started = ContinuousClock.now
        #expect(await call.value == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!process.isRunning)
    }
}
#endif
