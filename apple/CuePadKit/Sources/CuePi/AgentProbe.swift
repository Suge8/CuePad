#if os(macOS)
import CueStore
import CueText
import Foundation

/// 由已检测出的接入状态（`AgentIntegration.status(of:)`）得出这台 Mac 上各家能不能用（同步表 macAgents 里这台的那条）：
/// 装着、找得到命令行程序的几家问出不指定模型时用哪个、能选哪些（`MacAgent`），问得出、开得出会话才算能用（Pi 还要接入，见 `unconnected`）；
/// 其余与问不出的给出原因（`MacAgentProblem`，接在 Agent 名后面读，用户能照着办）。没接入的 Pi 也问：先报没登录，登录了才报只差接入，
/// 接入面板一打开就给对那一步。只读，不改任何一家的配置。
/// 每家起一个不落会话、不跑钩子、不连 CuePad 的进程，问完让它退出（各家怎么问在 `AgentFacts.probe`），各家并发、各自至多 `AgentTimeouts.probe`。
/// 起的是检测时挑中的那个可执行文件（`AgentStatus.executable`，与开会话、起大脑同一个）。
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
            return Self.unconnected(kind, status).map(Outcome.unusable) ?? .usable(agent)
        } catch let error as ProbeError {
            return .unusable(.other(ShownText(error)))
        } catch {
            return .unusable(.other(ShownText("问不出模型（\(error.localizedDescription.clipped(Self.messageLimit))）")))
        }
    }

    /// 原因里错误原话的字符数上限（含省略号）：原因跟着同步记录走，界面只显示一行。
    private static let messageLimit = 60

    /// 没装或太旧的原因（不用问）；装着为 nil。
    private static func absent(_ kind: AgentKind, _ status: AgentStatus) -> MacAgentProblem.Reason? {
        switch status.presence {
        case .notFound: .notInstalled
        case .unresponsive: .other(ShownText("问版本没有回应，稍后再试"))
        case .tooOld(let version): .other(ShownText("版本太旧（\(version.description)，要 \(kind.facts.minimumVersion?.description ?? "") 或更新）"))
        case .found: nil
        }
    }

    /// 问得出、却因为没接入开不出会话的原因；开得出为 nil。CuePad 写给多数家的文件（技能、钩子）只管终端里开的会话与历史，
    /// 后台开的会话由 CuePad 直接托管，没接入照样开得出；托管的会话也经上报通道上报的（`AgentFacts.hostingNeedsChannel`）没接入就开不出来。
    private static func unconnected(_ kind: AgentKind, _ status: AgentStatus) -> MacAgentProblem.Reason? {
        guard kind.facts.hostingNeedsChannel else { return nil }
        switch status.files {
        case .missing: return .notConnected
        case .foreign(let path): return .other(ShownText("接不上：\(path) 是别人的同名文件"))
        case .current, .outdated: return nil
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
