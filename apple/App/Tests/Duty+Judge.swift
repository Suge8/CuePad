#if os(macOS)
import CueStore
import Foundation
@testable import CuePad

@MainActor
extension Duty {
    // MARK: 判定

    /// 判定要看的那几步
    struct Points {
        let go, progress, readmeStatus, provider, tabs, e2e, trip, bounce, certified, wrap: Step
        /// 忘记密码的收尾：做完交回那一步，与 Cue 没收、会话补上版本号的那一步（有的话）
        let wrapUp: [Step]
        let cert: ScriptedSession
    }

    func judge(
        login: ScriptedSession, settings: ScriptedSession, site: ScriptedSession, digest: ScriptedSession,
        key: Points
    ) async throws -> [Check] {
        for session in sessions { try await session.refresh(rig) }
        let adds = CueEval.calls(in: rounds(after: steps.first!), "task", ["add"]).filter { CueEval.built($0.call) }
        let topics: [(String, Regex<Substring>)] = [
            ("忘记密码", /忘记密码|重置密码/), ("邮件服务", /服务|额度|哪家/), ("设置页", /设置页/), ("官网性能", /Lighthouse|性能/),
            ("README", /README/), ("依赖", /依赖/), ("周报", /周报/), ("死链", /死链/), ("SendGrid", /SendGrid/),
        ]
        let duplicated = topics.filter { _, topic in adds.count { ($0.args["title"] as? String)?.contains(topic) == true } > 1 }.map(\.0)
        let readmeAdds = adds.count { ($0.args["title"] as? String)?.contains(/README/) == true }
        let repeated = resaid()
        let unhandled = steps.filter { step in
            guard let session = step.session else { return false }
            return !calls(step, "task").contains { !$0.call.failed && target($0.args) === session } && calls(step, "tell").isEmpty
        }
        let afterRejection = try await eval.said(since: key.go.window?.upperBound ?? .distantFuture).map(\.text)
            + says(steps.filter { ($0.window?.lowerBound ?? .distantPast) > (key.go.window?.upperBound ?? .distantFuture) }, to: settings)
        let tabsAnswers = answers([key.tabs], to: settings), e2eAnswers = answers([key.e2e], to: site), providerAnswers = answers([key.provider], to: digest)
        // 升版本号：收尾跨做完交回与补上版本号两步，按先后看 Cue 的 task 调用：第一次 done 掉这件之前交代过它（交回没提时 say 让它补，或 edit、add、
        // 开工写着它的步骤），或它还排在没做完的步骤里（Cue 早先把它加成了步骤）。交回没提就 done 的不过；这件一直没 done 的不计
        let bump = /2\.3\.1|CHANGELOG|changelog/
        let wrapCalls = CueEval.calls(in: key.wrapUp.flatMap { rounds($0) }, "task")
        let closing = wrapCalls.firstIndex { $0.args["action"] as? String == "done" && !$0.call.failed && target($0.args) === login }
        let beforeClose = wrapCalls[..<(closing ?? wrapCalls.endIndex)].map { call in
            guard call.args["action"] as? String == "start" else { return Self.texts(call.args) }
            return login.cards.first { card in (call.args["task"] as? String).map { card.id.uuidString.lowercased().hasPrefix($0.lowercased()) } == true }?.body ?? ""
        }
        // 他要的：证书查完时告诉他签发方（会话交回里写着 Sectigo）
        let certDone = calls(key.certified, "task", ["done", "leave"]).contains { !$0.call.failed && target($0.args) === key.cert }
        let certSaid = try await told(key.certified)
        let loginDone = closing != nil
        let planned = try await rig.store.cueTaskDetail(login.task.id).leaves.contains { $0.leaf.status != .done && $0.leaf.body.contains(bump) }
        return [
            Check(.carry, "(a) 他口头交代的升 2.3.1、记 CHANGELOG：收尾时交代了，或排成了下一步",
                  beforeClose.contains { $0.contains(bump) } || planned, note: loginDone ? "" : "（这件没收尾）", counted: loginDone),
            Check(.memory, "(a) 他口头交代的：官网问跑不跑 e2e，答只跑单元测试", e2eAnswers == ["只跑单元测试就交"]),
            Check(.memory, "(b) 早先会话查清的：周报邮件问走哪家发信，答 Postmark", providerAnswers == ["Postmark"]),
            Check(.carry, "(c) README 只建了一个任务（问进展时没另建）", readmeAdds == 1 && calls(key.readmeStatus, "task", ["add", "start"]).isEmpty),
            Check(.carry, "(c) 每件事只建一个任务", duplicated.isEmpty, note: duplicated.isEmpty ? "" : "（重复：\(duplicated.joined(separator: "、"))）"),
            Check(.carry, "(c) 没对同一个会话把同一件事说两遍", repeated.isEmpty, note: repeated.isEmpty ? "" : "（\(repeated.map(\.title).joined(separator: "、"))）"),
            Check(.result, "(c) 会话的每次动静都有接手", unhandled.isEmpty, note: unhandled.isEmpty ? "" : "（没接：\(unhandled.map(\.label).joined(separator: "、"))）"),
            Check(.ask, "(d) 设置页问拆不拆标签页：按他说的保持一页，不留给他、不问他",
                  tabsAnswers == ["保持一页长列表"] && calls(key.tabs, "tell").allSatisfy { $0.args["ask"] == nil }),
            Check(.memory, "(d) 他否掉之后没再提分标签页", !afterRejection.contains(where: EvalReading.proposesTabs)),
            try await recalled("(e) 他顺口说的行程：答出下周三下午 3 点", key.trip) { $0.contains(/周三|28/) && $0.contains(/3 ?点|15[:：]|三点/) },
            try await recalled("(f) 已完成的调研里顺带的细节：答出 13 封", key.bounce) { $0.contains(/13|十三/) },
            Check(.carry, "(g) 证书查完时照他要的说了是哪家签发的", certSaid.contains { $0.localizedCaseInsensitiveContains("Sectigo") }, note: certDone ? "" : "（这一步没收尾）"),
            Check(.result, "问登录页进展：答了进展、没派新活", try await reply(key.progress)?.contains(/后端|前端|测试|接口/) == true && calls(key.progress, "task", ["add", "start"]).isEmpty),
            // 问进展时顺手纠正自己刚派偏的（停下、改口）不算；算的是为这句去催会话继续、问它做到哪（打断它这一轮）
            Check(.result, "问进展只照现状答：没 say 催会话", !(calls(key.progress, "task", ["say"]) + calls(key.readmeStatus, "task", ["say"]))
                .contains { ($0.args["text"] as? String)?.contains(/继续|接着|做到哪|进展|汇报|回报/) == true }),
            Check(.result, "问今天的事：回了他、没派新活", try await reply(key.wrap) != nil && calls(key.wrap, "task", ["add", "start"]).isEmpty),
        ]
    }

    // MARK: 统计

    /// 写进 .md 的长程统计
    func summarize() async {
        let rounds = eval.rounds.filter { $0.wake != .enabled }
        let renewals = eval.renewals
        let renewedAt = renewalModes.compactMap { round, mode in
            steps.firstIndex { $0.window?.contains(round.startedAt) == true }.map { "第 \($0 + 1) 步「\(steps[$0].label)」（\(mode)）" }
        }
        let lines = [
            "", "## 长程", "",
            "- 醒来 \(rounds.count) 次（不含预热；剧本叫醒 \(steps.count) 次），换新 \(renewals.count) 次（大脑开了新的对话）\(renewedAt.isEmpty ? "" : "，在" + renewedAt.joined(separator: "、"))",
        ]
        eval.report = lines + stepTable()
    }
}
#endif
