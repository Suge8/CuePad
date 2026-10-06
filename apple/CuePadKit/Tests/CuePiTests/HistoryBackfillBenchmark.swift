#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 首次回填（没有检查点：新装、或检查点格式升级后）的耗时与 CPU。默认不跑：
/// `CUEPAD_BENCH_SESSIONS=<会话目录> swift test --filter HistoryBackfillBenchmark`，目录用 `apple/scripts/gen-pi-sessions.py` 生成
/// （3000 个合成会话文件，其中 60 个在 7 天内修改过）。用 `-c release -Xswiftc -enable-testing` 跑，与发布版的速度可比。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUEPAD_BENCH_SESSIONS"] != nil))
struct HistoryBackfillBenchmark {
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    @Test func firstBackfillOfAllSessions() async throws {
        let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["CUEPAD_BENCH_SESSIONS"]), directoryHint: .isDirectory)
        let indexer = PiHistoryIndexer(root: root, transcriptWindow: 7 * 86_400) { _ in nil }
        let wall = ContinuousClock.now
        let cpu = Self.cpuSeconds()
        var files = 0, withMessages = 0, messages = 0
        for await event in indexer.events() {
            switch event {
            case .updated(let update):
                files += 1
                if !update.transcript.isEmpty { withMessages += 1 }
                messages += update.transcript.count
            case .backfillFinished:
                let elapsed = ContinuousClock.now - wall
                print("BENCH files=\(files) withMessages=\(withMessages) messages=\(messages) wall=\(elapsed) cpu=\(String(format: "%.1f", Self.cpuSeconds() - cpu))s")
                return
            }
        }
    }
}
#endif
