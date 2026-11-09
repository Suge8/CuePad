#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

extension CueEvalTests {
    /// 钉着三组重复的规矩（每组两三种说法）与两条各不相同的；他先叫它清理并给一条新原则，嫌没收口再追问一句（他的原话）。
    /// 要看：两轮回复回应整理请求与追问，重复确实合并，条件、范围、例外与原意不变；语义由 memory-judge.py 读实际结果判分。
    @Test func m整理钉着的记忆() async throws {
        try await CueEval.run(
            "m-整理钉着的记忆",
            expect: "钉着的规矩有三组重复；他叫它清理并给一条新原则、又追问为什么不收口：每组重复确实合并，允许同义改写但不改变条件、范围、例外与原意（原本已要求推送前 lint 和测试均通过、推送免询问；不得撤销检查通过要求或免询问，先跑不等于通过）；中文文案和新原则保留，回复回应用户并说清整理结果"
        ) { eval in
            let rig = eval.rig
            for text in Self.pinnedRules { try await rig.store.noteCueLine(text, source: .you, pinned: true) }
            let first = try #require(try await eval.settle { try await rig.say(Self.askTidy) })
            let firstReply = try await eval.reply(since: first.lowerBound)?.text ?? ""
            let second = try #require(try await eval.settle { try await rig.say(Self.pushBack) })
            let secondReply = try await eval.reply(since: second.lowerBound)?.text ?? ""

            let pinned = try await rig.store.cueMemory().lines.filter { $0.pinned && $0.deletedAt == nil }.map(\.text)
            eval.report.append("语义验收待 memory-judge.py 判分；以下自动检查仅确认记忆与回复已产出。")
            eval.report.append("整理前：\n" + Self.pinnedRules.map { "- " + $0 }.joined(separator: "\n"))
            eval.report.append("用户第一轮：" + Self.askTidy + "\n回复：" + firstReply)
            eval.report.append("用户追问：" + Self.pushBack + "\n回复：" + secondReply)
            eval.report.append("钉着的（做完时）：\n" + pinned.map { "- " + $0 }.joined(separator: "\n"))
            return [
                Check(.result, "两轮都回复了用户", !firstReply.isEmpty && !secondReply.isEmpty),
                Check(.result, "整理后仍有重点记忆", !pinned.isEmpty),
            ]
        }
    }

    static let allowance = "以后推送代码都不用问我，测试过了就推"
    static let pinnedRules = [
        "回复先说结论", "回复要先给结论，再给依据", "回复短一点，开头就是结论",
        "推送前先跑测试和 lint", "推送代码之前要先过 lint 和测试",
        "测试只写端到端的", "不写复述实现的单元测试，只写端到端测试",
        "界面文案默认用中文", allowance,
    ]
    static let askTidy = "你的记忆要清理下吗？我们的原则是：每块记忆一个写入者、不加锁、不回显。"
    static let pushBack = "不是 我看记忆很多重复的啊 你不整理收口吗"
}
#endif
