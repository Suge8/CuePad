#if os(macOS)
import CueStore
import CueText
import Foundation

/// 只读，不改任何一家的配置：每家起一个不落会话、不跑钩子、不连 CuePad 的进程，问完让它退出。接没接入不影响能不能用：后台开的会话都由 CuePad 直接托管。
struct AgentProbe {
    let paths: AgentPaths
    let locator: ExecutableLocator
    let timing: Timing

    private enum Outcome: Sendable {
        case usable(MacAgent)
        case unusable(MacAgentProblem.Reason)
    }

    func run(_ statuses: [AgentKind: AgentStatus]) async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        let outcomes = await withTaskGroup(of: (AgentKind, Outcome).self) { group in
            for (kind, status) in statuses { group.addTask { (kind, await outcome(kind, status)) } }
            return await group.reduce(into: [AgentKind: Outcome]()) { $0[$1.0] = $1.1 }
        }
        var agents: [MacAgent] = [], problems: [MacAgentProblem] = []
        for kind in AgentKind.allCases {
            switch outcomes[kind] {
            case .usable(let agent)?: agents.append(agent)
            case .unusable(let reason)?: problems.append(MacAgentProblem(kind: kind, reason: reason))
            case nil: break
            }
        }
        return (agents, problems)
    }

    private func outcome(_ kind: AgentKind, _ status: AgentStatus) async -> Outcome {
        if let reason = Self.absent(kind, status) { return .unusable(reason) }
        guard let executable = status.executable else { return .unusable(.other(ShownText("没找到它的命令行程序"))) }
        do {
            let agent = try await withDeadline(AgentTimeouts.probe, timing: timing, orThrow: ProbeError.timedOut) { [self] in
                try await kind.facts.probe(executable, self)
            }
            guard let agent else { return .unusable(.notLoggedIn) }
            return .usable(agent)
        } catch let error as ProbeError {
            return .unusable(.other(ShownText(error)))
        } catch {
            return .unusable(.other(ShownText("问不出模型（\(error.localizedDescription.clipped(Self.messageLimit))）")))
        }
    }

    /// 原因里错误原话的字符数上限（含省略号）：原因跟着同步记录走，界面只显示一行。
    private static let messageLimit = 60

    private static func absent(_ kind: AgentKind, _ status: AgentStatus) -> MacAgentProblem.Reason? {
        switch status.presence {
        case .notFound: .notInstalled
        case .unresponsive: .other(ShownText("问版本没有回应，稍后再试"))
        case .tooOld(let version): .other(ShownText("版本太旧（\(version.description)，要 \(kind.facts.minimumVersion?.description ?? "") 或更新）"))
        case .found: nil
        }
    }

    /// 随包插件（Pi 的桥扩展、dsh 的 cuepad 插件）在探测模式（`CUEPAD_PROBE`）写的一行 `{"cuepadProbe": {model, models}}`：
    /// 缺省模型与会话里的模型菜单同一份；一个模型都没有是没登录。
    struct PluginReply: Decodable {
        let cuepadProbe: Models
        struct Models: Decodable {
            let model: ModelOption?
            let models: [ModelOption]
        }

        init?(line: Data) {
            guard let reply = try? JSONDecoder().decode(Self.self, from: line) else { return nil }
            self = reply
        }

        func agent(_ kind: AgentKind) -> MacAgent? {
            cuepadProbe.models.isEmpty ? nil : MacAgent(kind: kind, model: cuepadProbe.model?.key, models: cuepadProbe.models)
        }
    }

    enum ProbeError: ShownError {
        case timedOut
        case noAnswer(status: Int32)
        var shown: String.LocalizationValue {
            switch self {
            case .timedOut: "问不出模型（\(AgentTimeouts.probe.components.seconds) 秒没回答）"
            case .noAnswer(let status): "问不出模型（没报模型就退出了，退出码 \(status)）"
            }
        }
    }
}
#endif
