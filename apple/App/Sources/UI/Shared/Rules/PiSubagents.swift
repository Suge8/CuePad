import CueStore
import Foundation

/// 子代理（FireCode 的子代理名册，经同步记录到手机）的展示规则，Mac 与手机同一份。
nonisolated extension [PiSubagentState] {
    /// 名册里每一个配上列表用的标识：名字可能重复（别家 Agent 的子代理按角色起名，同一个角色派了几个），同名的按出现先后编号。
    /// 名册只往后添，已有的编号不变。
    var identified: [(id: String, agent: PiSubagentState)] {
        var seen: [String: Int] = [:]
        return map { agent in
            let n = seen[agent.name, default: 0]
            seen[agent.name] = n + 1
            return ("\(agent.name)#\(n)", agent)
        }
    }
}

nonisolated extension PiSubagentState {
    /// 状态标借会话的说法：在跑的是工作中，失败是出错，其余（审查中、交回、被中断、空闲）是停着；状态词另写（`label`）。
    var shown: PiShown {
        switch phase.known {
        case .running: PiShown(state: .known(.thinking))
        case .failed: PiShown(state: .known(.error))
        case .review, .done, .interrupted, .idle: PiShown(state: .known(.settled))
        case nil: PiShown(state: .unknown(phase.rawValue))
        }
    }

    var label: String {
        switch phase.known {
        case .running: String(localized: "工作中")
        case .review: String(localized: "审查中")
        case .done: String(localized: "已交回")
        case .failed: String(localized: "失败")
        case .interrupted: String(localized: "被中断")
        case .idle: String(localized: "空闲")
        case nil: shown.label
        }
    }
}

/// 一行汇总：在跑的个数是主句（第一眼要看到的），共几个是次句，失败的另算；`lineup` 是在跑、失败的排前面的名册。没有子代理是 nil。
nonisolated struct PiSubagentSummary: Equatable {
    let running: Int
    let total: Int
    let failed: Int
    let lineup: [PiSubagentState]

    /// 主句：有在跑的写"2 个在跑"；都停了只写总数"8 个子代理"。
    var lead: String { running > 0 ? String(localized: "\(running) 个在跑") : String(localized: "\(total) 个子代理") }

    /// 次句：除了在跑的还有别的，补上总数"共 8 个"；全在跑或都停了没有。
    var tail: String? { running > 0 && total > running ? String(localized: "共 \(total) 个") : nil }

    /// 失败的个数写在末尾；没有失败时为 nil。
    var failure: String? { failed > 0 ? String(localized: "\(failed) 失败") : nil }

    init?(_ agents: [PiSubagentState]) {
        guard !agents.isEmpty else { return nil }
        running = agents.filter(\.isRunning).count
        total = agents.count
        failed = agents.filter { $0.phase == .known(.failed) }.count
        lineup = agents.filter(\.isRunning) + agents.filter { $0.phase == .known(.failed) } + agents.filter { !$0.isRunning && $0.phase != .known(.failed) }
    }
}

/// 子代理的时长怎么读：在跑的"运行了 4 分钟"从本次运行开始算，落定的"用时 5 分钟"停在落定时刻。没有开始时刻（空闲）没有时长。
nonisolated enum PiSubagentClock: Equatable {
    case running(PiClock)
    case took(TimeInterval)

    init?(_ agent: PiSubagentState) {
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
        case .took(let seconds): String(localized: "用时 \(PiClock.duration(seconds))")
        }
    }

}

/// 会话在等子代理时（`PiProgress` 的那一句）说是谁在干什么：只有一个在跑，写它的名字与动作；好几个在跑，说几个在跑；
/// 都不在跑了（交回了、在被审查，结果还没发给 Agent）说已交回。它接在状态词"子代理工作中"后面，不再说一遍"在干活"。
nonisolated enum PiSubagentLine {
    static func of(_ agents: [PiSubagentState]) -> String? {
        guard !agents.isEmpty else { return nil }
        let running = agents.filter(\.isRunning)
        switch running.count {
        case 0: return String(localized: "子代理已交回，等 Agent 接着做")
        case 1: return Dotted(running[0].name, running[0].action).visible
        default: return String(localized: "\(running.count) 个在跑")
        }
    }
}
