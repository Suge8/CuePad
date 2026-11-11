#if os(macOS)
import CueStore
import CueTestSupport
import Foundation

/// 后台的子代理与命令的剧本：主线程（有 Agent 工具）、子代理（有 SubagentHandback，交报告靠它）、后台完成的通知（`<task-notification>` 作为你的话进来）
/// 三种请求各演各的。话本身只是触发剧本的暗语。
extension ClaudeTestbed {
    static let backgroundWork = "BACKGROUND-WORK now"
    static let earlyReport = "EARLY-REPORT now"
    static let longSubagent = "LONG-SUBAGENT now"
    static let stopSubagent = "Stop the background subagent now with the TaskStop tool"

    /// 后台命令等 `finishBackgroundWork` 放行才做完：先后不靠时长拉开（子代理睡 3 秒、后台命令睡 6 秒时，慢机器上子代理连同它的几次请求超过 6 秒，
    /// 后台命令先交回，最后一轮答的是 SUB_DONE，等不到 BG_DONE）。
    func playBackgroundWork() {
        let background = gated(on: backgroundRelease, then: "BG_DONE")
        on("BACKGROUND-WORK") { request in
            switch request.step {
            case 0: launch("ticker", task: "SUBTASK-TICKER")
            case 1: .call("Bash", ["command": background, "run_in_background": true, "description": "bg"])
            default: .say("launched")
            }
        }
        on("SUBTASK-TICKER") { $0.step == 0 ? .call("Bash", ["command": "echo SUB_DONE", "description": "sub"]) : report("SUB_DONE", in: $0) }
        on("<task-notification>") { .say($0.prompt.contains("Background command") ? "BG_DONE" : "SUB_DONE") }
    }

    /// 交回子代理结果的那一轮做完、只剩后台命令在跑时，放它做完（终端里子代理做完就记成做完，早于交回它的那一轮，名册不够）。
    func finishBackgroundWork(_ id: Session.ID) async throws {
        try await eventually("交回子代理的那一轮做完，只等后台命令") {
            guard let session = bridge.session(id: id), session.state == .delegating else { return false }
            return (try? transcript(session.sessionFile))?.recap.lastReply?.contains("SUB_DONE") == true
        }
        try Data().write(to: backgroundRelease)
    }

    private var backgroundRelease: URL { root.appending(path: "background-release") }
    private var nestedRelease: URL { root.appending(path: "nested-release") }

    /// 子代理的后台命令等 `finishEarlyReport` 放行：先交回 WAITING、主线程答完，命令才做完（睡 5 秒时，慢机器上命令先做完，子代理不会先交回 WAITING）。
    func finishEarlyReport(_ id: Session.ID) async throws {
        try await eventually("子代理交回 WAITING，只等它的后台命令") {
            guard let session = bridge.session(id: id), session.state == .delegating else { return false }
            return (try? transcript(session.sessionFile))?.recap.lastReply?.contains("WAITING") == true
        }
        try Data().write(to: nestedRelease)
    }

    /// 子代理先交回 WAITING，名下的后台命令做完时它被叫醒再跑一次、再报 NESTED_DONE。2.1.318 的 SubagentHandback 只收一份报告，
    /// 叫醒后的这一份走 SendMessage（`to: main`；它是按需加载的工具，先 ToolSearch 取来）。叫醒它的通知和工具结果同在你的一条话里。
    /// 子代理的报告以 `<agent-message>` 作为你的话进主线程。
    func playEarlyReport() {
        let nested = gated(on: nestedRelease, then: "NESTED")
        on("EARLY-REPORT") { $0.step == 0 ? launch("nested", task: "SUBTASK-NESTED") : .say("launched") }
        // 叫醒后的工具结果与 "Tool loaded." 同在一条：最近一句话不再是交给它的任务，按整段对话认这个子代理
        model.on({ $0.tools.contains("SubagentHandback") && String(decoding: $0.body, as: UTF8.self).contains("SUBTASK-NESTED") }) { request in
            let last = request.lastUserMessage
            if last.contains(#""tool_reference""#) { return .call("SendMessage", ["to": "main", "summary": "nested done", "message": "NESTED_DONE"]) }
            if last.contains("<task-notification>") && last.contains(#"Background command \"nested\""#) {
                return .call("ToolSearch", ["query": "select:SendMessage", "max_results": 1])
            }
            return switch request.step {
            case 0: .call("Bash", ["command": nested, "run_in_background": true, "description": "nested"])
            case 1: handback("WAITING")
            default: .say("waiting")
            }
        }
        let report: @Sendable (FakeRequest) -> FakeReply = { request in
            request.tools.contains("SubagentHandback") ? .say("waiting") : .say(String(decoding: request.body, as: UTF8.self).contains("NESTED_DONE") ? "NESTED_DONE" : "WAITING")
        }
        on("<agent-message", reply: report)
        on("<task-notification>", reply: report)
    }

    func playLongSubagent() {
        let victim = #"python3 -c "import time; time.sleep(60)"; echo V"#
        on("LONG-SUBAGENT") { $0.step == 0 ? launch("victim", task: "SUBTASK-VICTIM") : .say("launched") }
        on("SUBTASK-VICTIM") { $0.step == 0 ? .call("Bash", ["command": victim, "description": "victim"]) : report("V", in: $0) }
        on("TaskStop") { request in
            guard request.step == 0 else { return .say("STOPPED") }
            let agent = String(decoding: request.body, as: UTF8.self).firstMatch(of: /agentId: (\w+)/)?.1
            return .call("TaskStop", ["task_id": agent.map(String.init) ?? ""])
        }
        on("<task-notification>") { _ in .say("STOPPED") }
    }
}

private func gated(on marker: URL, then echo: String) -> String { #"while [ ! -e '\#(marker.path)' ]; do sleep 0.05; done; echo \#(echo)"# }

private func launch(_ description: String, task: String) -> FakeReply {
    .call("Agent", ["subagent_type": "general-purpose", "run_in_background": true, "description": description, "prompt": task])
}

private func handback(_ message: String) -> FakeReply { .call("SubagentHandback", ["message": message]) }

/// 托管（stream-json）里的子代理有 SubagentHandback、靠它交报告；终端里的没有，最后一句话就是报告
private func report(_ message: String, in request: FakeRequest) -> FakeReply {
    request.tools.contains("SubagentHandback") ? handback(message) : .say(message)
}

private extension FakeRequest {
    /// 对话里最后一条你的话的原文（JSON；之后可能还跟着 system 消息）
    var lastUserMessage: String {
        let last = (json["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "user" }
        return last.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
#endif
