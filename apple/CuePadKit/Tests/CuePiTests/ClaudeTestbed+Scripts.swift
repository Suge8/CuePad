#if os(macOS)
import CueTestSupport
import Foundation

/// 后台的子代理与命令的剧本：主线程（有 Agent 工具）、子代理（有 SubagentHandback，交报告靠它）、后台完成的通知（`<task-notification>` 作为你的话进来）
/// 三种请求各演各的。话本身只是触发剧本的暗语。
extension ClaudeTestbed {
    static let backgroundWork = "BACKGROUND-WORK now"
    static let longSubagent = "LONG-SUBAGENT now"
    static let stopSubagent = "Stop the background subagent now with the TaskStop tool"

    func playBackgroundWork() {
        let background = python(sleeping: 6, then: "BG_DONE")
        on("BACKGROUND-WORK") { request in
            switch request.step {
            case 0: launch("ticker", task: "SUBTASK-TICKER")
            case 1: .call("Bash", ["command": background, "run_in_background": true, "description": "bg"])
            default: .say("launched")
            }
        }
        on("SUBTASK-TICKER") { $0.step == 0 ? .call("Bash", ["command": python(sleeping: 3, then: "SUB_DONE"), "description": "sub"]) : handback("SUB_DONE") }
        on("<task-notification>") { .say($0.prompt.contains("Background command") ? "BG_DONE" : "SUB_DONE") }
    }

    func playLongSubagent() {
        let victim = python(sleeping: 60, then: "V")
        on("LONG-SUBAGENT") { $0.step == 0 ? launch("victim", task: "SUBTASK-VICTIM") : .say("launched") }
        on("SUBTASK-VICTIM") { $0.step == 0 ? .call("Bash", ["command": victim, "description": "victim"]) : handback("V") }
        on("TaskStop") { request in
            guard request.step == 0 else { return .say("STOPPED") }
            let agent = String(decoding: request.body, as: UTF8.self).firstMatch(of: /agentId: (\w+)/)?.1
            return .call("TaskStop", ["task_id": agent.map(String.init) ?? ""])
        }
        on("<task-notification>") { _ in .say("STOPPED") }
    }
}

private func python(sleeping seconds: Int, then echo: String) -> String { #"python3 -c "import time; time.sleep(\#(seconds))"; echo \#(echo)"# }

private func launch(_ description: String, task: String) -> FakeReply {
    .call("Agent", ["subagent_type": "general-purpose", "run_in_background": true, "description": description, "prompt": task])
}

private func handback(_ message: String) -> FakeReply { .call("SubagentHandback", ["message": message]) }
#endif
