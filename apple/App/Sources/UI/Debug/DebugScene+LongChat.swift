#if DEBUG
import CueStore
import Foundation

/// 长对话与追加中的对话（验收会话页的滚动，iOS 与 Mac 共用）：
/// - `-CuePadLongChat YES`（配 `-CuePadDemo YES`）：演示库多一个 300 轮的会话 marathon（CuePad 项目），回答高矮悬殊——
///   一句话、整页长段落、40 行代码块、宽表、长列表轮换，每 25 轮你贴进来一段长文；看打开即最新、往上翻、回到最新。
/// - `-CuePadStream YES`（配 session 画面）：打开会话后像真的 Agent 那样一轮一轮追加（`stream`）：看新内容到达时跟随最新，
///   也查会话在跑时才有的界面（经过、子代理、回复框的停止钮）。
/// - `-CuePadBench chatscroll`（仅 Mac，配 session 画面打开 marathon，或 cue 画面量 Cue 页的长对话）：在进程内投递滚轮与触控板事件滚对话，量每圈主线程 CPU 与指令数（`ChatScrollBench`）。
extension DebugScene {
    static let longChat = "marathon"
    private static let longChatRounds = 300

    static func seedLongChat(_ store: CueStore, project: UUID?) async {
        _ = try? await PiStateRecorder(store: store, hostID: "demo-mac").update(
            sessionID: longChat, state: .settled, title: longChat, directory: longChat, projectID: project)
        let start = Date.now.addingTimeInterval(-Double(longChatRounds) * 240)
        let turns = (0..<longChatRounds).map { round in
            let asked = start.addingTimeInterval(Double(round) * 240)
            return ChatTurn(you: longChatPrompt(round), pi: longChatReply(round), tools: nil, asked: asked, answered: asked.addingTimeInterval(60))
        }
        try? await writeChat(longChat, turns, store: store)
    }

    /// 给 `sessionID` 像真的 Agent 那样一轮一轮追加，共 `rounds` 轮：你的话 → 每 200ms 做完一步（经过清单变长、状态在思考与跑工具之间换、
    /// 子代理名册变）→ 第 15 步落回答（高矮轮换）→ 等子代理时它交回一张机器消息卡片 → 歇下。
    static func stream(_ sessionID: String, rounds: Int = 100, store: CueStore) async {
        guard let session = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: sessionID))).items.first?.state else { return }
        let recorder = PiStateRecorder(store: store, hostID: session.hostID, minInterval: .zero)
        func set(_ state: PiWorkState, detail: String? = nil, agents: [PiSubagentState]) async {
            _ = try? await recorder.update(
                sessionID: sessionID, state: state, detail: detail, title: session.title, directory: session.folder, projectID: session.projectID, subagents: agents)
        }
        func write(_ messages: [PiChatMessage], _ recap: PiRecap) async {
            try? await store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: messages, recap: recap))
        }
        for round in 0..<rounds {
            let seq = Int64(1_000_000 + round * 3)
            let you = PiChatMessage(sessionID: sessionID, entryID: "stream-u\(round)", seq: seq, role: .user, text: longChatPrompt(round + 1), at: .now)
            await write([you], PiRecap(pendingPrompt: you.text))
            var tools = PiChatMessage.Tools()
            for step in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                tools.record(.init(kind: step % 4 == 0 ? .said : .command, target: step % 4 == 0 ? "看一下第 \(step) 步的输出" : "pnpm test -- --run case\(step)"))
                await write([], PiRecap(pendingPrompt: you.text, pendingTools: tools))
                let helper = PiSubagentState(name: "helper-\(round)", role: "工程师", phase: .known(.running), action: "第 \(step) 步", startedAt: you.at)
                await set(step % 2 == 0 ? .tool : .thinking, detail: step % 2 == 0 ? "bash · pnpm test case\(step)" : nil, agents: [helper])
            }
            let answer = PiChatMessage(
                sessionID: sessionID, entryID: "stream-p\(round)", seq: seq + 1, role: .pi, text: longChatReply(round + 1), at: .now, tools: tools, roundStartedAt: you.at)
            await write([answer], PiRecap(lastPrompt: you.text, lastReply: answer.text))
            let helper = PiSubagentState(name: "helper-\(round)", role: "工程师", phase: .known(.running), action: "收尾", startedAt: you.at)
            await set(.delegating, agents: [helper])
            try? await Task.sleep(for: .seconds(1))
            let returned = PiChatMessage(
                sessionID: sessionID, entryID: "stream-m\(round)", seq: seq + 2, role: .machine,
                text: "<firecode_master_event>\nhelper-\(round) 交回：\(longChatReply(round))\n</firecode_master_event>", at: .now)
            await write([returned], PiRecap(lastPrompt: you.text, lastReply: answer.text))
            await set(.settled, agents: [PiSubagentState(name: "helper-\(round)", role: "工程师", phase: .known(.done), startedAt: you.at, settledAt: .now)])
            try? await Task.sleep(for: .seconds(1))
        }
    }

    static func longChatPrompt(_ round: Int) -> String {
        guard round % 25 != 0 else {
            return "第 \(round) 轮，我把日志贴过来：\n" + (1...30).map { "[\($0)] worker-\($0 % 7) retry=\($0 % 3) 连接被对端重置，正在重连第 \($0) 次" }.joined(separator: "\n")
        }
        return ["继续", "第 \(round) 轮：把上一步的结果整理成表格", "这里为什么会慢？给我看一下热点代码", "好，下一个", "列一下还剩哪些没做"][round % 5]
    }

    static func longChatReply(_ round: Int) -> String {
        let paragraph = "第 \(round) 轮的回答。调度器在重连时会拿到新的时间戳，所以按加入时间排序会把重连的人排到最前；改成按首次加入时间排序之后，"
            + "重连不再改变顺序，压测里 p95 从 12ms 降到 9ms，内存基本不变。另外两条超时路径还没有用例覆盖，补上之后覆盖率能到 85% 左右。"
        switch round % 6 {
        case 0: return "好的，第 \(round) 轮做完了。"
        case 1: return Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        case 2: return paragraph + "\n\n```swift\n" + (1...40).map { "let value\($0) = try await compute(\($0), retry: \($0 % 5))" }.joined(separator: "\n") + "\n```"
        case 3:
            return "| 用例 | 结果 | 耗时 | 说明 |\n|:--|:--:|--:|:--|\n"
                + (1...8).map { "| 用例 \($0) | \($0 % 3 == 0 ? "失败" : "通过") | \($0 * 13) ms | 第 \(round) 轮的第 \($0) 个检查 |" }.joined(separator: "\n")
        case 4: return (1...12).map { "- 第 \($0) 项：" + ($0 % 2 == 0 ? "已完成" : "还差一点，等上游合并") }.joined(separator: "\n")
        default: return paragraph
        }
    }
}
#endif
