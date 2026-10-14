#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 子进程超时的边界契约。
@MainActor
struct ExitContractTests {
    /// 取消调用方不撤掉超时：超时到了照样终止进程并返回 nil，不拿取消当退出码。
    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerKeepsTheTimeout() async throws {
        let call = Task { await runCapturing(URL(filePath: "/bin/sleep"), ["5"], timeout: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(50))
        call.cancel()
        #expect(await call.value == nil)  // 超时被撤掉就等到 sleep 正常退出，返回退出码
    }
}
#endif
