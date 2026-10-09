import CueStore
import Foundation
import Testing
@testable import CuePad

/// 书架顶上的"Agent 此刻"一条：主句只说谁、在怎样（一行放得下），次行说它在问什么、在做什么；好几个时主句说个数、次行带过其余的。
/// 会话多了不加行，只变数字与叠放的头像。要紧的先后与 Agent 页列表一致（`PiShown.rank`）；停着的不算。
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

    @Test func 只有一件时主句说谁在怎样_次行说它在问什么做什么() {
        let deploy = now([item("deploy", .waitingForUser, question: "部署到生产吗？\n会替换当前线上的 1.4.2", folder: "ops")])
        #expect(deploy?.headline == "deploy 在等你确认")
        #expect(deploy?.detail == "部署到生产吗？")
        #expect(deploy?.needsYou == true)

        let atlas = now([item("atlas", .tool, detail: "bash · pnpm test")])
        #expect(atlas?.headline == "atlas 在干活")
        #expect(atlas?.detail == "运行 pnpm test")
        #expect(atlas?.needsYou == false)
        let notes = now([item("notes", .settled, reply: "整理好了。三件待办。")])
        #expect(notes?.headline == "notes 回复了")
        #expect(notes?.detail == "整理好了。")
    }

    /// 只有一个在跑时次行让给它在做什么：其余的在叠放的头像与 Agent 页里。说不出在做什么时才带过其余的，再没有就写在哪。
    @Test func 只有一件时次行先写它在做什么_说不出才写其余的或在哪() {
        let reload = item("old-term", .incompatible, folder: "ops")
        #expect(now([item("atlas", .tool, detail: "bash · pnpm test"), reload])?.detail == "运行 pnpm test")
        #expect(now([reload])?.detail == "在 ops")
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

    /// 要紧的先后与点进去的 Agent 页列表同一套（`PiShown.rank`）：要重载排在在干活之后、有新回复之前。
    /// 首页面向人，不写终端命令：怎么重载写在那个会话页里。
    @Test func 要紧先后与Agent页列表一致() {
        let reload = item("old-term", .incompatible), notes = item("notes", .settled, reply: "整理好了。")
        #expect(now([notes, reload])?.headline == "old-term 要在终端里重载")
        #expect(now([notes, reload])?.detail == "还有 1 个有新回复")
        #expect(now([item("a", .tool, detail: "bash · ls"), reload, item("b", .incompatible)])?.detail == "运行 ls")
        #expect(now([item("a", .thinking), item("b", .thinking), reload, item("c", .incompatible)])?.detail == "还有 2 个要重载")
    }

    @Test func 都停着时没有这一条() {
        #expect(now([item("old", .settled, reply: "早就看过了。"), item("done", .ended)]) == nil)
    }
}
