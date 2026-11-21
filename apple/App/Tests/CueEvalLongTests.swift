#if os(macOS)
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries, .enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(60)))
struct CueEvalLongTests {
    nonisolated static let runs = max(1, Int(evalEnvironment["CUEPAD_CUE_EVAL_RUNS"] ?? "") ?? 1)

    @Test(arguments: 1...runs) func 长程值班(_ run: Int) async throws {
        let output = Self.runs == 1 ? evalOutput : URL(filePath: evalOutput.path + "-\(run)", directoryHint: .isDirectory)
        try await CueEval.run("长程", expect: Duty.expect, suite: .long, output: output, rig: {
            try await CueHostTests.Rig(brain: .current, cacheLifetime: Duty.cacheLifetime, renewAt: Duty.renewAt)
        }) { try await Duty($0).play() }
    }
}
#endif
