#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation

/// 这台 Mac 上的 Agent 能不能用、各家的模型（同步表 macAgents）只经这里写：按检测出的接入状态问（`AgentIntegrations.probe`），
/// 内容变了才写，写了立即上传；各处读库，这里不留结果。
/// 一次问完再问下一次，后问的不会被先问的覆盖；还没开始的那一次，期间要问的都并进去。
/// 什么时候问：各家接入状态都检测出来、状态变了、系统唤醒时（`keep`，睡着时可能登录、换了模型配置），以及 Cue 启用前
/// （`record`：等这一次写完再按库里的判断，刚启动还没问完时启用也不会读到旧的或空的）。
@MainActor
final class MacAgentsRecorder {
    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let host: String
    private let agents: AgentIntegrations
    /// 最近排上的那一次，与它开始问了没有
    private var latest: Task<MacAgents, any Error>?
    private var latestStarted = true

    init(store: CueStore, sync: (any SyncControlling)?, host: String, agents: AgentIntegrations) {
        self.store = store
        self.sync = sync
        self.host = host
        self.agents = agents
    }

    /// 重新问一次并写下，返回写完后库里这台 Mac 的那条。
    @discardableResult
    func record() async throws -> MacAgents {
        if let latest, !latestStarted { return try await latest.value }
        let before = latest
        latestStarted = false
        let round = Task { [self] in
            _ = await before?.result
            latestStarted = true
            let found = await agents.probe()
            if let id = try await store.recordMacAgents(host: host, found.agents, problems: found.problems) { await sync?.upload(id) }
            return try await store.macAgents(on: host)
        }
        latest = round
        return try await round.value
    }

    /// 跟着接入状态与系统唤醒问，直到任务取消。
    func keep(notifications center: NotificationCenter) async throws {
        let statuses = Observations { [agents] in agents.statuses }
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) { try await self.record() }
            }
            group.addTask {
                var asked: [AgentKind: AgentStatus]?
                for await now in statuses where now.count == AgentKind.allCases.count && now != asked {
                    asked = now
                    try await self.record()
                }
            }
        }
    }
}
#endif
