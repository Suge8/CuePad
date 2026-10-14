import CueStore
import Foundation

/// 子代理（FireCode 的子代理名册，经同步记录到手机）的展示规则，Mac 与手机同一份。
nonisolated extension PiSubagentState {
    /// 在跑：自己在工作，或在被审查（审查期间它自己是闲的，但这件事还没完）。
    var isRunning: Bool { phase == .known(.running) || phase == .known(.review) }

    /// 状态标与状态词借会话的说法：干活的是工作中，失败是出错，其余（交回、被中断、空闲）是停着。
    var shown: PiShown {
        switch phase.known {
        case .running, .review: PiShown(state: .known(.thinking))
        case .failed: PiShown(state: .known(.error))
        case .done, .interrupted, .idle: PiShown(state: .known(.settled))
        case nil: PiShown(state: .unknown(phase.rawValue))
        }
    }

    /// 角色的图标（会话卡片上一个子代理一个）：FireCode 角色表里的角色各一个，认不出的角色是一个人。
    var roleSymbol: String { Self.roleSymbols[role] ?? "person.fill" }

    private static let roleSymbols = [
        "调研员": "magnifyingglass", "工程师": "hammer.fill", "批量工": "square.stack.3d.up.fill", "设计师": "paintbrush.pointed.fill",
        "哨兵": "binoculars.fill",
    ]

    var label: String {
        switch phase.known {
        case .running: "工作中"
        case .review: "审查中"
        case .done: "已交回"
        case .failed: "失败"
        case .interrupted: "被中断"
        case .idle: "空闲"
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
    var lead: String { running > 0 ? "\(running) 个在跑" : "\(total) 个子代理" }

    /// 次句：除了在跑的还有别的，补上总数"共 8 个"；全在跑或都停了没有。
    var tail: String? { running > 0 && total > running ? "共 \(total) 个" : nil }

    /// 失败的个数写在末尾；没有失败时为 nil。
    var failure: String? { failed > 0 ? "\(failed) 失败" : nil }

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
        case .took(let seconds): "用时 \(PiClock.duration(seconds))"
        }
    }

}

/// 会话在等子代理时（`PiProgress` 的那一句）说它们在干什么：只有一个在跑，写它的名字与动作；好几个在跑，说个数；
/// 都停了（结果还没发给 Agent）说已交回。
nonisolated enum PiSubagentLine {
    static func of(_ agents: [PiSubagentState]) -> String? {
        guard !agents.isEmpty else { return nil }
        let running = agents.filter(\.isRunning)
        switch running.count {
        case 0: return "子代理已交回，等 Agent 接着做"
        case 1:
            let agent = running[0]
            return agent.action.isEmpty ? "\(agent.name) 在干活" : "\(agent.name) 在干活：\(agent.action)"
        default: return "\(running.count) 个子代理在干活"
        }
    }
}
