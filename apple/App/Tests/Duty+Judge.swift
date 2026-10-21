#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

@MainActor
extension Duty {
    // MARK: 判定

    /// 判定要看的那几步
    struct Points {
        let go, progress, readmeStatus, provider, tabs, e2e, trip, bounce, finish, certified, wrap: Step
        let cert: ScriptedSession
    }

    func judge(
        login: ScriptedSession, settings: ScriptedSession, site: ScriptedSession, digest: ScriptedSession,
        key: Points
    ) async throws -> [Check] {
        for session in sessions { try await session.refresh(rig) }
        let adds = CueEval.calls(in: rounds(after: steps.first!), "task", ["add"]).filter { !$0.call.failed }
        let topics: [(String, Regex<Substring>)] = [
            ("忘记密码", /忘记密码|重置密码/), ("邮件服务", /服务|额度|哪家/), ("设置页", /设置页/), ("官网性能", /Lighthouse|性能/),
            ("README", /README/), ("依赖", /依赖/), ("周报", /周报/), ("死链", /死链/), ("SendGrid", /SendGrid/),
        ]
        let duplicated = topics.filter { _, topic in adds.count { ($0.args["title"] as? String)?.contains(topic) == true } > 1 }.map(\.0)
        let readmeAdds = adds.count { ($0.args["title"] as? String)?.contains(/README/) == true }
        let repeated = sessions.filter { session in
            let said = says(steps, to: session)
            return said.indices.contains { i in said[(i + 1)...].contains { Self.similar($0, said[i]) } }
        }
        let unhandled = steps.filter { step in
            guard let session = step.session else { return false }
            return !calls(step, "task").contains { !$0.call.failed && target($0.args) === session } && calls(step, "tell").isEmpty
        }
        let afterRejection = try await eval.said(since: key.go.window?.upperBound ?? .distantFuture).map(\.text)
            + says(steps.filter { ($0.window?.lowerBound ?? .distantPast) > (key.go.window?.upperBound ?? .distantFuture) }, to: settings)
        let tabsSaid = says([key.tabs], to: settings), e2eSaid = says([key.e2e], to: site), providerSaid = says([key.provider], to: digest)
        // 升版本号：收尾时交代（say、edit、add，或开工写着它的步骤），或还排在这件事没做完的步骤里（Cue 早先把它加成了步骤）
        let bump = /2\.3\.1|CHANGELOG|changelog/
        let started = CueEval.calls(in: rounds(key.finish), "task", ["start"]).compactMap { call in
            login.cards.first { card in (call.args["task"] as? String).map { card.id.uuidString.lowercased().hasPrefix($0.lowercased()) } == true }?.body
        }
        // 他要的：证书查完时告诉他签发方（会话交回里写着 Sectigo）
        let certDone = calls(key.certified, "task", ["done", "leave"]).contains { !$0.call.failed && target($0.args) === key.cert }
        let certSaid = try await messages(key.certified) + calls(key.certified, "tell").compactMap { $0.args["text"] as? String }
        let loginDone = calls(key.finish, "task", ["done"]).contains { !$0.call.failed && target($0.args) === login }
        let wrapUp = CueEval.calls(in: rounds(key.finish), "task", ["say", "edit", "add"]).map { Self.texts($0.args) } + started
        let planned = try await rig.store.cueTaskDetail(login.task.id).leaves.contains { $0.leaf.status != .done && $0.leaf.body.contains(bump) }
        return [
            Check(.carry, "(a) 他口头交代的升 2.3.1、记 CHANGELOG：收尾时交代了，或排成了下一步",
                  wrapUp.contains { $0.contains(bump) } || planned, note: loginDone ? "" : "（这件没收尾）", counted: loginDone),
            Check(.memory, "(a) 他口头交代的：官网问跑不跑 e2e，答只跑单元测试", e2eSaid.contains { $0.contains(/单元|只跑|不跑|别跑/) } && !e2eSaid.contains { $0.contains("跑 e2e 回归") || $0 == "1" }),
            Check(.memory, "(b) 早先会话查清的：周报邮件问走哪家发信，答 Postmark", providerSaid.contains { $0.localizedCaseInsensitiveContains("Postmark") } && !providerSaid.contains { $0 == "SendGrid" || $0 == "1" }),
            Check(.carry, "(c) README 只建了一个任务（问进展时没另建）", readmeAdds == 1 && calls(key.readmeStatus, "task", ["add", "start"]).isEmpty),
            Check(.carry, "(c) 每件事只建一个任务", duplicated.isEmpty, note: duplicated.isEmpty ? "" : "（重复：\(duplicated.joined(separator: "、"))）"),
            Check(.carry, "(c) 没对同一个会话把同一件事说两遍", repeated.isEmpty, note: repeated.isEmpty ? "" : "（\(repeated.map(\.title).joined(separator: "、"))）"),
            Check(.result, "(c) 会话的每次动静都有接手", unhandled.isEmpty, note: unhandled.isEmpty ? "" : "（没接：\(unhandled.map(\.label).joined(separator: "、"))）"),
            Check(.ask, "(d) 设置页问拆不拆标签页：按他说的保持一页，不留给他、不问他",
                  tabsSaid.contains { $0.contains(/一页|不拆|保持|不分|别拆|不要/) } && !tabsSaid.contains { $0 == "拆成标签页" || $0 == "1" }
                    && calls(key.tabs, "tell").allSatisfy { $0.args["ask"] == nil }),
            Check(.memory, "(d) 他否掉之后没再提分标签页", !afterRejection.contains(where: Self.proposesTabs)),
            try await recalled("(e) 他顺口说的行程：答出下周三下午 3 点", key.trip) { $0.contains(/周三|28/) && $0.contains(/3 ?点|15[:：]|三点/) },
            try await recalled("(f) 已完成的调研里顺带的细节：答出 13 封", key.bounce) { $0.contains(/13|十三/) },
            Check(.carry, "(g) 证书查完时照他要的说了是哪家签发的", certSaid.contains { $0.localizedCaseInsensitiveContains("Sectigo") }, note: certDone ? "" : "（这一步没收尾）"),
            Check(.result, "问登录页进展：答了进展、没派新活", try await reply(key.progress)?.contains(/后端|前端|测试|接口/) == true && calls(key.progress, "task", ["add", "start"]).isEmpty),
            Check(.result, "问今天的事：回了他、没派新活", try await reply(key.wrap) != nil && calls(key.wrap, "task", ["add", "start"]).isEmpty),
        ]
    }

    /// 说到分标签页、又不是在否定它（前面几个字里没有不、别、没、无）；"按标签定位"这类说的是别的标签
    static func proposesTabs(_ text: String) -> Bool {
        text.ranges(of: /标签页|页签|tab ?页|tabs/.ignoresCase()).contains { range in
            let from = text.index(range.lowerBound, offsetBy: -8, limitedBy: text.startIndex) ?? text.startIndex
            return !text[from..<range.lowerBound].contains(/不|别|没|无|免|否/)
        }
    }

    // MARK: 统计

    /// 写进 .md 的长程统计，与汇总行的两格
    func summarize() async {
        let rounds = eval.rounds.filter { $0.wake != .enabled }
        let durations = rounds.compactMap { round in round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } }.sorted()
        let median = durations.isEmpty ? "—" : seconds(durations.count.isMultiple(of: 2)
            ? (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2 : durations[durations.count / 2])
        let renewals = eval.renewals
        let renewedAt = renewalModes.compactMap { round, mode in
            steps.firstIndex { $0.window?.contains(round.startedAt) == true }.map { "第 \($0 + 1) 步「\(steps[$0].label)」（\(mode)）" }
        }
        let usage = rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []
        let total = usage.reduce(BrainUsage(), +)
        eval.overview = (rounds.reduce(0) { $0 + $1.calls.count }, "中位 \(median)")
        var lines = [
            "", "## 长程", "",
            "- 醒来 \(rounds.count) 次（不含预热；剧本叫醒 \(steps.count) 次），换新 \(renewals.count) 次（大脑开了新的对话）\(renewedAt.isEmpty ? "" : "，在" + renewedAt.joined(separator: "、"))",
            "- 每轮用时中位 \(median)",
            "- 合计（含预热，大脑报了 \(usage.count) 轮）：\(BrainUsage.header.replacingOccurrences(of: " | ", with: "、")) = \(total.cells.replacingOccurrences(of: " | ", with: "、"))",
        ]
        lines += notes.map { "- \($0)" }
        lines += ["", "| 步 | 叫醒的事 | 轮数 | 工具调用 |", "| --- | --- | --- | --- |"]
        for (index, step) in steps.enumerated() {
            let rounds = self.rounds(step)
            lines.append("| \(index + 1) | \(step.label) | \(rounds.count) | \(rounds.flatMap(\.calls).map(\.name).joined(separator: "、")) |")
        }
        eval.report = lines
        eval.extra["renewals"] = renewalModes.map { round, mode in
            ["mode": mode, "step": steps.first { $0.window?.contains(round.startedAt) == true }?.label ?? "—"]
        }
    }
}
#endif
