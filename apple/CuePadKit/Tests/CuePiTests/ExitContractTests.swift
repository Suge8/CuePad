#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 退出收尾与子进程超时的边界契约。
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

    /// 退出时主线程可能被占住（terminate 在主线程的嵌套事件循环里等回复）：`closeAll` 返回的等待不需要主线程。
    @Test(.enabled(if: realPiAvailable, "需要 ~/.local/bin/pi"), .timeLimit(.minutes(2)))
    func theWaitReturnedByCloseAllDoesNotNeedTheMainThread() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = PiHost(bridge: bridge, paths: pi.paths, extraArguments: PiProcess.quietArguments)
        host.start()
        _ = try await host.open(in: pi.cwd, launchToken: "tok-exit", executable: realPiURL)

        let wait = host.closeAll()
        let done = DispatchSemaphore(value: 0)
        Task.detached { await wait(); done.signal() }
        #expect(Self.blockMainThread(until: done, seconds: 10))
    }

    private nonisolated static func blockMainThread(until signal: DispatchSemaphore, seconds: Double) -> Bool {
        signal.wait(timeout: .now() + seconds) == .success
    }
}
#endif
