import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目的"此刻"一行（书架大卡与行、iPad、Mac 侧栏共用）：每个项目只挑一件最该知道的事，按优先取第一个——
/// 等你确认（它在问什么）→ 出错（原因）→ Agent 在跑（在做什么）→ 有新回复（回复第一句）→ 进行中的任务 → 项目介绍；都没有就没有。
struct ProjectNowTests {
    let project = UUID()

    private func item(
        _ id: String, _ state: PiWorkState, detail: String? = nil, question: String? = nil, reply: String? = nil, project: UUID? = nil
    ) -> PiSessionListItem {
        let at = Date(timeIntervalSince1970: 100)
        return PiSessionListItem(state: PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: project ?? self.project, state: .known(state), detail: detail,
            folder: nil, lastPrompt: "做一下", lastReply: reply, question: question.map { PiQuestion(promptID: nil, kind: .text, text: $0) },
            notify: nil, stateSince: at, busySince: at, createdAt: at, modifiedAt: at))
    }

    /// 回复第一句只在你没看过时算"有新回复"：测试里 notes 没看过，其余停着的都看过。
    private func shown(_ item: PiSessionListItem) -> PiShown {
        PiShown(item.state, delivery: item.delivery, unread: item.state.sessionID == "notes")
    }

    private func now(_ sessions: [PiSessionListItem], task: String? = "补重连用例", intro: String? = "多 Agent 调度本月可上线") -> ProjectNow? {
        ProjectNow.pick(sessions, shown: shown, task: task, intro: intro)
    }

    @Test func 按优先只挑一件() {
        let asking = item("rename", .waitingForUser, question: "新分支叫什么？\n随便起一个")
        let broken = item("billing", .error, detail: "模型拒绝了请求（400）")
        let busy = item("atlas", .tool, detail: "bash · pnpm test")
        let unread = item("notes", .settled, reply: "整理好了。三件待办。")
        let seen = item("old", .settled, reply: "早就看过了。")

        #expect(now([busy, broken, asking, unread])?.text == "新分支叫什么？")
        #expect(now([busy, unread, broken])?.text == "模型拒绝了请求（400）")
        #expect(now([unread, busy])?.text == "运行 pnpm test")
        #expect(now([seen, unread])?.text == "整理好了。")
        #expect(now([seen])?.text == "补重连用例")
        #expect(now([seen], task: nil)?.text == "多 Agent 调度本月可上线")
        #expect(now([seen], task: nil, intro: nil) == nil)
    }

    @Test func 只看本项目的会话_颜色只给等你确认与出错() {
        let elsewhere = item("deploy", .waitingForUser, question: "部署到生产吗？", project: UUID())
        let busy = item("atlas", .tool, detail: "bash · pnpm test")

        let byProject = ProjectNow.byProject([project], live: [elsewhere, busy], tasks: [:], intros: [:], shown: shown)

        #expect(byProject[project]?.text == "运行 pnpm test")
        #expect(byProject[project]?.needsYou == false)
        #expect(now([item("rename", .waitingForUser, question: "新分支叫什么？")])?.needsYou == true)
    }
}
