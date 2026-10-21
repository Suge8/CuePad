#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 长程值班：Cue 值一段班，被叫醒二十多次（他的话、会话歇下带长回复、会话提问、出错），回复撑大上下文，至少跨一次换新线。
/// 中后段的判定点只有记得前面才答得对：他口头交代、没让记成规矩的细节，早先会话交回的事实，正在推进的事不重做不丢，他否掉的方案不再提；
/// 换新之后还有三处 Cue 当场没理由落库的：他顺口说的与任务无关的事实、已完成的事里会话顺带提的细节、他要它查完时告诉他的事。
/// 要等收尾才兑现的两处（升版本号、证书签发方）看那一步 Cue 有没有收尾：没收尾的升版本号不算，签发方照样要说。
/// 换新那一刻丢没丢东西：换新线缩到场景跑得到的值（`renewAt`），缓存时长缩短、中途他走开一阵（冷换新）；几样只在原始上下文里出现过的
/// （会话交回里的细节、他托付给它的打算、它对方案的判断、一件逐页推进的多步活）在换新前埋下、换新后考，每处标出跨了哪种换新（热、冷）。
/// 只经库与假会话驱动、只读库与工具调用判定，不碰 Cue 的内部状态（换新次数从大脑的输出里数）。跑法见 docs/verify.md「Cue 评测」。
@Suite(.enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(60)))
struct CueEvalLongTests {
    /// 同时跑几遍（`CUEPAD_CUE_EVAL_RUNS`，缺省 1）：多遍时第 n 遍写到"输出目录-n"
    nonisolated static let runs = max(1, Int(evalEnvironment["CUEPAD_CUE_EVAL_RUNS"] ?? "") ?? 1)

    @Test(arguments: 1...runs) func 长程值班(_ run: Int) async throws {
        let output = Self.runs == 1 ? evalOutput : URL(filePath: evalOutput.path + "-\(run)", directoryHint: .isDirectory)
        try await CueEval.run("长程", expect: Duty.expect, suite: .long, output: output, rig: {
            try await CueHostTests.Rig(brain: .current, cacheLifetime: Duty.cacheLifetime, renewAt: Duty.renewAt)
        }) { try await Duty($0).play() }
    }
}
#endif
