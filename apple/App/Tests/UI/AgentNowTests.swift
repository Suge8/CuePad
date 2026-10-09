import CueStore
import Foundation
import Testing
@testable import CuePad

/// 书架顶上的"Agent 此刻"一条：按最要紧的事用人话说一句（谁、在怎样），次行补充其余的；会话多了不加行，只变数字与叠放的头像。
/// 要紧的先后与 PiShown 一致：等你确认 → 出错（含没能送达）与要 /reload → 在干活（含话在路上）→ 有新回复；停着的不算。
struct AgentNowTests {
    private func item(
        _ id: String, _ state: PiWorkState, detail: String? = nil, question: String? = nil, reply: String? = nil, folder: String? = nil
    ) -> PiSessionListItem {
        let at = Date(timeIntervalSince1970: 100)
        return PiSessionListItem(state: PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: detail, folder: folder,
            lastPrompt: "做一下", lastReply: reply, question: question.map { PiQuestion(promptID: nil, kind: .confirm, text: $0) },
            notify: nil, stateSince: at, busySince: at, createdAt: at, modifiedAt: at))
    }

    /// notes 停下后你还没看（有新回复），其余停着的都看过。
    private func now(_ sessions: [PiSessionListItem]) -> AgentNow? {
        AgentNow.of(sessions) { PiShown($0.state, delivery: $0.delivery, unread: $0.state.sessionID == "notes") }
    }

    @Test func 只有一件时说清是谁在怎样_次行写在哪() {
        let deploy = now([item("deploy", .waitingForUser, question: "部署到生产吗？\n会替换当前线上的 1.4.2", folder: "ops")])
        #expect(deploy?.headline == "deploy 在问：部署到生产吗？")
        #expect(deploy?.detail == "在 ops")
        #expect(deploy?.needsYou == true)

        #expect(now([item("atlas", .tool, detail: "bash · pnpm test")])?.headline == "atlas 在干活：运行 pnpm test")
        #expect(now([item("notes", .settled, reply: "整理好了。三件待办。")])?.headline == "notes 回复了：整理好了。")
        #expect(now([item("atlas", .tool, detail: "bash · pnpm test")])?.needsYou == false)
    }

    @Test func 同一件事好几个时说个数_次行列名字() {
        let busy = now([item("atlas", .tool, detail: "bash · pnpm test"), item("cuepad", .thinking), item("review", .delegating)])
        #expect(busy?.headline == "3 个 Agent 在干活")
        #expect(busy?.detail == "atlas、cuepad、review")
    }

    @Test func 最要紧的当主句_其余的在次行一句带过() {
        let mixed = now([
            item("atlas", .tool, detail: "bash · pnpm test"), item("billing", .error, detail: "模型拒绝了请求"),
            item("deploy", .waitingForUser, question: "部署到生产吗？"), item("rename", .waitingForUser, question: "新分支叫什么？"),
        ])
        #expect(mixed?.headline == "2 个 Agent 在等你确认")
        #expect(mixed?.detail == "还有 1 个出错 · 1 个在干活")
        #expect(mixed?.needsYou == true)
    }

    @Test func 头像最多叠三个_多的写个数() {
        let six = now((1...6).map { item("s\($0)", .thinking) } + [item("ask", .waitingForUser, question: "要覆盖吗？")])
        #expect(six?.faces.map(\.state.sessionID) == ["ask", "s1", "s2"])
        #expect(six?.more == 4)
    }

    /// 要紧的先后与点进去的 Agent 页列表同一套（`PiShown.rank`）：要 /reload 排在在干活之后、有新回复之前。
    @Test func 要紧先后与Agent页列表一致() {
        let reload = item("old-term", .incompatible), notes = item("notes", .settled, reply: "整理好了。")
        #expect(now([notes, reload])?.headline == "old-term 要在终端里 /reload")
        #expect(now([notes, reload])?.detail == "还有 1 个有新回复")
    }

    @Test func 都停着时没有这一条() {
        #expect(now([item("old", .settled, reply: "早就看过了。"), item("done", .ended)]) == nil)
    }
}
