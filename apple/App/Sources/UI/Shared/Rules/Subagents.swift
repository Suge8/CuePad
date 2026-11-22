import CueStore
import Foundation

nonisolated extension [SubagentState] {
    var identified: [(id: String, agent: SubagentState)] {
        var seen: [String: Int] = [:]
        return map { agent in
            let n = seen[agent.name, default: 0]
            seen[agent.name] = n + 1
            return ("\(agent.name)#\(n)", agent)
        }
    }
}

nonisolated extension SubagentState {
    var shown: SessionShown {
        switch phase.known {
        case .running: SessionShown(state: .known(.thinking))
        case .failed: SessionShown(state: .known(.error))
        case .review, .paused, .done, .rejected, .interrupted, .idle: SessionShown(state: .known(.settled))
        case nil: SessionShown(state: .unknown(phase.rawValue))
        }
    }

    var label: String {
        switch phase.known {
        case .running: String(localized: "工作中")
        case .review: String(localized: "审查中")
        case .paused: String(localized: "稍后重试")
        case .done: String(localized: "已交回")
        case .failed: String(localized: "失败")
        case .rejected: String(localized: "未通过")
        case .interrupted: String(localized: "被中断")
        case .idle: String(localized: "空闲")
        case nil: shown.label
        }
    }
}

nonisolated struct SubagentSummary: Equatable {
    let running: Int
    let total: Int
    let failed: Int
    let rejected: Int
    let lineup: [SubagentState]

    var lead: String { running > 0 ? String(localized: "\(running) 个工作中") : String(localized: "\(total) 个子代理") }

    var tail: String? { running > 0 && total > running ? String(localized: "共 \(total) 个") : nil }

    var failure: String? { failed > 0 ? String(localized: "\(failed) 失败") : nil }

    var rejection: String? { rejected > 0 ? String(localized: "\(rejected) 未通过") : nil }

    init?(_ agents: [SubagentState]) {
        guard !agents.isEmpty else { return nil }
        running = agents.filter(\.isRunning).count
        total = agents.count
        failed = agents.filter { $0.phase == .known(.failed) }.count
        rejected = agents.filter { $0.phase == .known(.rejected) }.count
        lineup = agents.filter(\.isRunning) + agents.filter { $0.phase == .known(.failed) } + agents.filter { !$0.isRunning && $0.phase != .known(.failed) }
    }
}

nonisolated enum SubagentClock: Equatable {
    case running(SessionClock)
    case took(TimeInterval)

    init?(_ agent: SubagentState) {
        guard let started = agent.startedAt else { return nil }
        if agent.isRunning {
            self = .running(.running(since: started))
        } else if let settled = agent.settledAt {
            self = .took(settled.timeIntervalSince(started))
        } else {
            return nil
        }
    }

    func text(now: Date) -> String {
        switch self {
        case .running(let clock): clock.text(now: now)
        case .took(let seconds): String(localized: "用时 \(SessionClock.duration(seconds))")
        }
    }

}

nonisolated enum SubagentLine {
    static func of(_ agents: [SubagentState]) -> String? {
        guard !agents.isEmpty else { return nil }
        let running = agents.filter(\.isRunning)
        switch running.count {
        case 0: return String(localized: "子代理已交回，等 Agent 接着做")
        case 1: return Dotted(running[0].name, running[0].action).visible
        default: return String(localized: "\(running.count) 个工作中")
        }
    }
}
